using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace GraphCode.Validation.Ownership;

// Shared by the compiled supervisor and the PowerShell packaging/UIA adapters.
public static class StandaloneProcessJob
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr Min, Max;
        public uint Active;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Limits
    {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Accounting
    {
        public long User, Kernel, PeriodUser, PeriodKernel;
        public uint Faults, Total, Active, Terminated;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int info, ref Limits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int info, out Accounting value, uint size, IntPtr length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int info, IntPtr buffer, uint size, IntPtr length);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr Create()
    {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new Limits();
        limits.Basic.Flags = 0x2000;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Limits>()))
        {
            var primary = new Win32Exception();
            if (!CloseHandle(job))
                primary.Data["JobCloseFailure"] = new Win32Exception();
            throw primary;
        }
        return job;
    }

    public static bool Contains(IntPtr job, IntPtr process)
    {
        if (job == IntPtr.Zero || process == IntPtr.Zero)
            throw new ArgumentException("Held process and job handles are required.");
        if (!IsProcessInJob(process, job, out bool result)) throw new Win32Exception();
        return result;
    }

    public static void Assign(IntPtr job, IntPtr process)
    {
        if (!AssignProcessToJobObject(job, process)) throw new Win32Exception();
        if (!Contains(job, process)) throw new InvalidOperationException("Assigned root is not in the held job.");
    }

    public static uint Active(IntPtr job)
    {
        if (!QueryInformationJobObject(job, 1, out Accounting value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero))
            throw new Win32Exception();
        return value.Active;
    }

    public static string Summary(IntPtr job)
    {
        if (!QueryInformationJobObject(job, 1, out Accounting value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero))
            throw new Win32Exception();
        return $"total={value.Total}; active={value.Active}; terminated={value.Terminated}; user100ns={value.User}; kernel100ns={value.Kernel}";
    }

    public static int[] Members(IntPtr job)
    {
        const int capacity = 4096;
        int size = 8 + capacity * IntPtr.Size;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            if (!QueryInformationJobObject(job, 3, buffer, (uint)size, IntPtr.Zero))
                throw new Win32Exception();
            int assigned = Marshal.ReadInt32(buffer, 0), count = Marshal.ReadInt32(buffer, 4);
            if (count < 0 || count > capacity || assigned != count)
                throw new InvalidOperationException("Incomplete owned job member census.");
            var result = new int[count];
            for (int i = 0; i < count; i++)
                result[i] = checked((int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64());
            return result;
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static string Processes(IntPtr job)
    {
        var identities = new List<string>();
        foreach (int pid in Members(job))
        {
            IntPtr process = OpenProcess(0x1000, false, (uint)pid);
            if (process == IntPtr.Zero)
            {
                identities.Add($"pid={pid}; unavailable-win32={Marshal.GetLastWin32Error()}");
                continue;
            }
            try
            {
                if (!Contains(job, process))
                {
                    identities.Add($"pid={pid}; no-longer-owned");
                    continue;
                }
                uint length = 32768;
                var name = new StringBuilder((int)length);
                if (!GetProcessTimes(process, out long creation, out _, out _, out _) ||
                    !QueryFullProcessImageNameW(process, 0, name, ref length))
                {
                    identities.Add($"pid={pid}; identity-unavailable-win32={Marshal.GetLastWin32Error()}");
                    continue;
                }
                identities.Add($"pid={pid}; creationUtcTicks={DateTime.FromFileTimeUtc(creation).Ticks}; name={System.IO.Path.GetFileNameWithoutExtension(name.ToString())}; imagePath={name}");
            }
            finally { if (!CloseHandle(process)) throw new Win32Exception(); }
        }
        return string.Join(" | ", identities);
    }

    public static void Terminate(IntPtr job)
    {
        if (!TerminateJobObject(job, 124)) throw new Win32Exception();
    }

    public static void WaitForEmpty(IntPtr job, int milliseconds)
    {
        if (milliseconds < 0) throw new ArgumentOutOfRangeException(nameof(milliseconds));
        WaitForEmpty(job, new Deadline(TimeSpan.FromMilliseconds(Math.Max(1, milliseconds))));
    }

    public static void WaitForEmpty(IntPtr job, Deadline deadline)
    {
        while (Active(job) != 0)
        {
            if (deadline.Expired) throw new TimeoutException("Owned job still has active processes.");
            Thread.Sleep(Math.Min(10, deadline.RemainingMilliseconds));
        }
    }

    public static void Close(IntPtr job)
    {
        if (Active(job) != 0) throw new InvalidOperationException("Cannot release a nonempty or unknown owned job.");
        if (!CloseHandle(job)) throw new Win32Exception();
    }
}
