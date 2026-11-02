using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public interface IOwnedCleanupAuthority
{
    string Identity { get; }
    bool OwnershipUnproven { get; }
    Task<string>? StandardOutput { get; }
    Task<string>? StandardError { get; }
    void Terminate();
    Task<bool> WaitForJobEmptyAsync(Deadline deadline);
    Task<bool> WaitForRootExitAsync(Deadline deadline);
    IReadOnlyList<Action> CloseActions { get; }
    void Retain(Exception failure);
}

public static class OwnedCleanupCoordinator
{
    public static async Task<OwnedCleanupProof> CompleteAsync(IOwnedCleanupAuthority authority, Exception? primary,
        TimeSpan timeout)
    {
        var deadline = new Deadline(timeout);
        var failures = new List<Exception>();
        if (authority.OwnershipUnproven)
        {
            var unknownProof = new OwnedCleanupProof(false, false,
                authority.StandardOutput?.IsCompletedSuccessfully ?? true,
                authority.StandardError?.IsCompletedSuccessfully ?? true, false);
            foreach (Task<string>? reader in new[] { authority.StandardOutput, authority.StandardError })
                if (reader?.IsFaulted == true) failures.Add(reader.Exception!);
            var unknown = new AggregateException("OWNED_CLEANUP_UNPROVEN: live descendant retention signal; termination and close withheld.", failures);
            Exception reported = primary ?? unknown;
            reported.Data["OwnedCleanupProof"] = unknownProof;
            reported.Data["OwnedCleanupFailure"] = unknown;
            authority.Retain(reported);
            if (primary == null) throw unknown;
            return unknownProof;
        }
        bool rootExited = false, jobEmpty = false;
        bool outEof = authority.StandardOutput == null, errEof = authority.StandardError == null;
        try
        {
            authority.Terminate();
        }
        catch (Exception failure) { failures.Add(failure); }
        try
        {
            jobEmpty = await authority.WaitForJobEmptyAsync(deadline).ConfigureAwait(false);
            if (!jobEmpty) failures.Add(new InvalidOperationException("Owned job quiescence unproved."));
        }
        catch (Exception failure) { failures.Add(failure); }
        try
        {
            rootExited = await authority.WaitForRootExitAsync(deadline).ConfigureAwait(false);
            if (!rootExited) failures.Add(new InvalidOperationException("Held root exit unproved."));
        }
        catch (Exception failure) { failures.Add(failure); }
        foreach (var stream in new[]
        {
            (Task: authority.StandardOutput, Name: "stdout"),
            (Task: authority.StandardError, Name: "stderr")
        })
        {
            if (stream.Task == null) continue;
            try
            {
                await stream.Task.WaitAsync(deadline.Remaining).ConfigureAwait(false);
                if (stream.Name == "stdout") outEof = true; else errEof = true;
            }
            catch (Exception failure) { failures.Add(new IOException(stream.Name + " EOF unproved.", failure)); }
        }
        bool closed = false;
        if (!authority.OwnershipUnproven && new OwnedCleanupProof(rootExited, jobEmpty, outEof, errEof, false).CanRelease)
        {
            closed = true;
            foreach (Action close in authority.CloseActions)
            {
                try { close(); }
                catch (Exception failure) { failures.Add(failure); closed = false; }
            }
        }
        var proof = new OwnedCleanupProof(rootExited, jobEmpty, outEof, errEof, closed);
        if (primary != null) primary.Data["OwnedCleanupProof"] = proof;
        if (!closed || failures.Count != 0)
        {
            var cleanup = new AggregateException($"OWNED_CLEANUP_UNPROVEN: {authority.Identity}; proof={proof}", failures);
            Exception reported = primary ?? cleanup;
            reported.Data["OwnedCleanupProof"] = proof;
            reported.Data["OwnedCleanupFailure"] = cleanup;
            if (!closed) authority.Retain(reported);
            if (primary == null) throw cleanup;
        }
        return proof;
    }
}
