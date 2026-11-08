using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Collections.Generic;

namespace GraphCode;

public static class ValidationFixtureDirectoryNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes { public uint Length; public IntPtr Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential)]
    private struct FileInformation
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetTokenInformation(IntPtr token, int kind, IntPtr buffer, uint length, out uint needed);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetLengthSid(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)] private static extern bool IsValidSid(IntPtr sid);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr text);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string text, uint revision, out IntPtr descriptor, out uint size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "CreateDirectoryW", ExactSpelling = true, SetLastError = true)]
    private static extern bool CreateDirectoryWithOwner(string path, ref SecurityAttributes attributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out FileInformation information);
    [DllImport("advapi32.dll")]
    private static extern uint GetSecurityInfo(IntPtr handle, int kind, uint information, out IntPtr owner,
        IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll")] private static extern bool EqualSid(IntPtr first, IntPtr second);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);

    public static void Create(string path)
    {
        if (!CreateDirectoryW(path, IntPtr.Zero))
        {
            var error = Marshal.GetLastWin32Error();
            throw new Win32Exception(error, $"Exclusive validation fixture create failed (Win32 {error}): {path}");
        }
    }

    public static void CreateOwnedWith(string path, Func<byte[]> userSid,
        Func<string, byte[], int> create, Action<string, byte[]> verify)
    {
        if (userSid == null || create == null || verify == null) throw new ArgumentNullException();
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path) ||
            !string.Equals(Path.GetFullPath(path), path, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Owned fixture path must be a normalized absolute path.", nameof(path));
        byte[] sid = userSid();
        if (sid == null || sid.Length < 8) throw new InvalidOperationException("Current token user SID is unavailable.");
        int error = create(path, sid);
        if (error != 0) throw new Win32Exception(error, $"Exclusive owned fixture creation failed (Win32 {error}): {path}");
        verify(path, sid);
    }

    public static string CurrentUserDescriptor(string sid)
    {
        if (sid == null || !Regex.IsMatch(sid, @"\AS-1-(?:\d+-)+\d+\z"))
            throw new ArgumentException("Current user SID descriptor is invalid.", nameof(sid));
        return "O:" + sid + "D:P(A;OICI;FA;;;" + sid + ")";
    }

    public static void ReleaseOwnedWith(Exception? primary, params Action[] releases)
    {
        var failures = new List<Exception>();
        foreach (Action release in releases)
        {
            try { release(); }
            catch (Exception failure) { failures.Add(failure); }
        }
        if (failures.Count == 0) return;
        var cleanup = new AggregateException("Owned fixture resource release failed.", failures);
        if (primary != null) primary.Data["OwnedFixtureReleaseFailures"] = cleanup;
        else throw cleanup;
    }

    private static void FreeOwnedLocal(IntPtr memory)
    {
        if (memory == IntPtr.Zero) return;
        IntPtr remaining = LocalFree(memory);
        int error = Marshal.GetLastWin32Error();
        if (remaining == IntPtr.Zero) return;
        if (error == 0) throw new InvalidOperationException("Owned LocalFree failed without a native error.");
        throw new Win32Exception(error);
    }

    private static void CloseOwnedHandle(IntPtr handle)
    {
        bool closed = CloseHandle(handle);
        int error = Marshal.GetLastWin32Error();
        if (closed) return;
        if (error == 0) throw new InvalidOperationException("Owned CloseHandle failed without a native error.");
        throw new Win32Exception(error);
    }

    public static void CreateOwnedByCurrentUser(string path)
    {
        var parent = new DirectoryInfo(Path.GetDirectoryName(path) ?? throw new ArgumentException("Missing parent."));
        for (var directory = parent; directory != null; directory = directory.Parent)
            if (!directory.Exists || (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidOperationException("Owned fixture parent is missing or a reparse point.");
        CreateOwnedWith(path, ReadCurrentUserSid, CreateWithOwner, VerifyOwner);
    }

    private static byte[] ReadCurrentUserSid()
    {
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out IntPtr token)) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr buffer = IntPtr.Zero;
        Exception? primary = null;
        try
        {
            bool first = GetTokenInformation(token, 1, IntPtr.Zero, 0, out uint needed);
            int error = Marshal.GetLastWin32Error();
            if (first || error != 122 || needed < IntPtr.Size || needed > 65536)
                throw new Win32Exception(error, "Current token user sizing failed.");
            buffer = Marshal.AllocHGlobal(checked((int)needed));
            if (!GetTokenInformation(token, 1, buffer, needed, out uint actual)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (actual > needed || actual < IntPtr.Size) throw new InvalidOperationException("Token user buffer length differs.");
            IntPtr sid = Marshal.ReadIntPtr(buffer);
            if (sid.ToInt64() < buffer.ToInt64() || sid.ToInt64() > buffer.ToInt64() + actual - 8)
                throw new InvalidOperationException("Token SID is outside its retained buffer.");
            if (!IsValidSid(sid)) throw new InvalidOperationException("Current token user SID is invalid.");
            uint length = GetLengthSid(sid);
            if (length < 8 || length > actual || sid.ToInt64() + length > buffer.ToInt64() + actual)
                throw new InvalidOperationException("Current token SID length is invalid.");
            byte[] bytes = new byte[length];
            Marshal.Copy(sid, bytes, 0, bytes.Length);
            return bytes;
        }
        catch (Exception failure) { primary = failure; throw; }
        finally
        {
            ReleaseOwnedWith(primary,
                () => { if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer); },
                () => CloseOwnedHandle(token));
        }
    }

    private static int CreateWithOwner(string path, byte[] sid)
    {
        GCHandle pin = default;
        IntPtr sidText = IntPtr.Zero, descriptor = IntPtr.Zero;
        Exception? primary = null;
        try
        {
            pin = GCHandle.Alloc(sid, GCHandleType.Pinned);
            if (!ConvertSidToStringSidW(pin.AddrOfPinnedObject(), out sidText)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string owner = Marshal.PtrToStringUni(sidText) ?? throw new InvalidOperationException("SID conversion failed.");
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(CurrentUserDescriptor(owner), 1, out descriptor, out _))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var attributes = new SecurityAttributes { Length = checked((uint)Marshal.SizeOf<SecurityAttributes>()), Descriptor = descriptor };
            bool created = CreateDirectoryWithOwner(path, ref attributes);
            int error = created ? 0 : Marshal.GetLastWin32Error();
            if (!created && error == 0) throw new InvalidOperationException("Owned fixture create failed without a native error.");
            if (!created) throw new Win32Exception(error);
            return error;
        }
        catch (Exception failure) { primary = failure; throw; }
        finally
        {
            ReleaseOwnedWith(primary,
                () => FreeOwnedLocal(descriptor),
                () => FreeOwnedLocal(sidText),
                () => { if (pin.IsAllocated) pin.Free(); });
        }
    }

    private static void VerifyOwner(string path, byte[] sid)
    {
        IntPtr handle = CreateFileW(path, 0x00020000, 0x00000001, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr descriptor = IntPtr.Zero;
        GCHandle pin = default;
        Exception? primary = null;
        try
        {
            pin = GCHandle.Alloc(sid, GCHandleType.Pinned);
            if (!GetFileInformationByHandle(handle, out FileInformation information)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((information.Attributes & 0x10) == 0 || (information.Attributes & 0x400) != 0)
                throw new InvalidOperationException("Fresh owned fixture is not a non-reparse directory.");
            uint error = GetSecurityInfo(handle, 1, 1, out IntPtr owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out descriptor);
            if (error != 0) throw new Win32Exception(checked((int)error));
            if (owner == IntPtr.Zero || descriptor == IntPtr.Zero || !EqualSid(owner, pin.AddrOfPinnedObject()))
                throw new InvalidOperationException("Fresh fixture owner differs from the current token user.");
        }
        catch (Exception failure) { primary = failure; throw; }
        finally
        {
            ReleaseOwnedWith(primary,
                () => FreeOwnedLocal(descriptor),
                () => { if (pin.IsAllocated) pin.Free(); },
                () => CloseOwnedHandle(handle));
        }
    }
}
