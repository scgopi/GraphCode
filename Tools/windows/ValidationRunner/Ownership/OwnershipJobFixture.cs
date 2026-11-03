using System;

namespace GraphCode.Validation.Ownership;

public static class OwnershipJobFixture
{
    public static bool Empty;
    public static int Terminated, Closed;
    public static void Terminate(IntPtr job) => Terminated++;
    public static void WaitForEmpty(IntPtr job, int timeout)
    {
        if (!Empty) throw new InvalidOperationException("Controlled fake job has a survivor.");
    }
    public static int Active(IntPtr job) => Empty ? 0 : 1;
    public static void Close(IntPtr job) => Closed++;
}
