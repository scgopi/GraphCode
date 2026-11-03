namespace GraphCode.Validation.Host;

public static class TerminalSafety
{
    private static int reportedUnknown;

    public static void MarkUnknown() => Interlocked.Exchange(ref reportedUnknown, 1);

    public static Task ExitBarrier(int retainedLeaseCount, bool unknownReported)
    {
        if (retainedLeaseCount == 0 && !unknownReported) return Task.CompletedTask;
        // Never complete this task: process exit would implicitly close retained kill-on-close jobs.
        return new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously).Task;
    }

    public static async Task PreserveRetainedAuthorityAsync(int retainedLeaseCount)
    {
        var barrier = ExitBarrier(retainedLeaseCount, Volatile.Read(ref reportedUnknown) != 0);
        if (barrier.IsCompleted) return;
        try { Console.Error.WriteLine("ROOT_AUTHORITY_RETAINED: terminal hold; manual ownership recovery required"); }
        finally { await barrier; }
    }
}
