using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace GraphCode;

public static class ValidationFixtureDirectoryNative
{
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
}
