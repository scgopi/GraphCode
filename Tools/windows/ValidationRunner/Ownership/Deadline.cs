using System;
using System.Diagnostics;

namespace GraphCode.Validation.Ownership;

public sealed class Deadline
{
    private readonly long started = Stopwatch.GetTimestamp();
    private readonly TimeSpan budget;

    public Deadline(TimeSpan budget)
    {
        if (budget <= TimeSpan.Zero || budget.TotalMilliseconds > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(budget));
        this.budget = budget;
    }

    public TimeSpan Remaining
    {
        get
        {
            TimeSpan remaining = budget - Stopwatch.GetElapsedTime(started);
            return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
        }
    }

    public int RemainingMilliseconds => (int)Math.Ceiling(Remaining.TotalMilliseconds);
    public bool Expired => Remaining == TimeSpan.Zero;
}
