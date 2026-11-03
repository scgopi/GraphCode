using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public static class ShellScopeNativeFixture
{
    public const int ExpectedCases = 44;

    public static async Task<int?> TryRunAsync(string mode, string root)
    {
        if (mode is "shell-scope-child" or "shell-scope-exit")
        {
            for (int index = 0; index < 16; index++)
                new Thread(() => Thread.Sleep(30000)) { IsBackground = true }.Start();
            Console.Out.WriteLine("shell-scope-ready");
            Console.Error.WriteLine("shell-scope-stderr");
            if (mode == "shell-scope-child") await Task.Delay(30000).ConfigureAwait(false);
            else
            {
                var limit = new Deadline(TimeSpan.FromSeconds(5));
                while (!File.Exists(Path.Combine(root, "release")))
                {
                    if (limit.Expired) throw new TimeoutException("Controlled natural exit release was not published.");
                    await Task.Delay(5).ConfigureAwait(false);
                }
            }
            return 7;
        }
        if (mode != "shell-scope-regression") return null;
        int executed = 0, pendingAtZero = 0;
        var natural = ShellOwnedLaunch.Suspended(OwnedFixture.Command("shell-scope-exit", root));
        try
        {
            IntPtr original = natural.Handle;
            Refuse(() => natural.RequireExited());
            executed++;
            Refuse(() => natural.RequireExited(20));
            executed++;
            bool rejected = false;
            try { natural.RequireExited(-1); }
            catch (ArgumentOutOfRangeException) { rejected = true; }
            Require(rejected && natural.Handle == original && !natural.Process.HasExited,
                "A live-root refusal released or replaced the original held authority.");
            executed++;
            natural.Resume();
            File.WriteAllText(Path.Combine(root, "release"), "released");
            natural.RequireExited(5000);
            natural.Drain();
            Require(natural.Process.ExitCode == 7 && natural.Handle == original &&
                natural.Output.Result.Contains("shell-scope-ready", StringComparison.Ordinal) &&
                natural.Error.Result.Contains("shell-scope-stderr", StringComparison.Ordinal),
                "Natural held-root exit lost identity, code or independent stream evidence.");
            executed++;
        }
        finally { ReleaseNatural(natural); }

        for (int iteration = 0; iteration < 10; iteration++)
        {
            IntPtr job = StandaloneProcessJob.Create();
            var runs = new List<ShellOwnedLaunch>();
            try
            {
                for (int index = 0; index < 4; index++)
                {
                    var run = ShellOwnedLaunch.Suspended(OwnedFixture.Command("shell-scope-child", root));
                    runs.Add(run);
                    StandaloneProcessJob.Assign(job, run.Handle);
                    run.Resume();
                }
                var ready = new HashSet<ShellOwnedLaunch>();
                var startup = new Deadline(TimeSpan.FromSeconds(5));
                while (ready.Count != runs.Count)
                {
                    foreach (var run in runs)
                        if (!ready.Contains(run) && run.TakeOutput(65536).Contains("shell-scope-ready", StringComparison.Ordinal))
                            ready.Add(run);
                    if (startup.Expired) throw new TimeoutException("Controlled scope roots did not all become ready.");
                    await Task.Delay(5).ConfigureAwait(false);
                }
                var exit = new Deadline(TimeSpan.FromSeconds(5));
                StandaloneProcessJob.Terminate(job);
                StandaloneProcessJob.WaitForEmpty(job, exit.RemainingMilliseconds);
                foreach (var run in runs)
                {
                    try { run.RequireExited(); }
                    catch (InvalidOperationException) { pendingAtZero++; }
                    run.RequireExited(exit.RemainingMilliseconds);
                    Require(StandaloneProcessJob.Active(job) == 0, "Owned job became active after termination.");
                    run.Drain();
                    Require(run.Output.Result.Contains("shell-scope-ready", StringComparison.Ordinal) &&
                        run.Error.Result.Contains("shell-scope-stderr", StringComparison.Ordinal),
                        "Terminated root lost independent EOF/output evidence.");
                    executed++;
                }
            }
            finally { ReleaseJob(job, runs); }
        }
        Require(executed == ExpectedCases, "Native scope fixture did not execute its exact case inventory.");
        Console.WriteLine("SHELL_NATIVE_RESULT=" + JsonSerializer.Serialize(new { executed, passed = executed, failed = 0, pendingAtZero }));
        return 0;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void Refuse(Action action)
    {
        bool rejected = false;
        try { action(); }
        catch (InvalidOperationException) { rejected = true; }
        Require(rejected, "A still-live held root was incorrectly accepted as exited.");
    }

    private static void ReleaseNatural(ShellOwnedLaunch run)
    {
        try { run.Stop(); run.RequireExited(); run.Close(); }
        catch (Exception failure) { Retain(failure); }
    }

    private static void ReleaseJob(IntPtr job, IReadOnlyList<ShellOwnedLaunch> runs)
    {
        try
        {
            var deadline = new Deadline(TimeSpan.FromSeconds(5));
            StandaloneProcessJob.Terminate(job);
            StandaloneProcessJob.WaitForEmpty(job, deadline.RemainingMilliseconds);
            foreach (var run in runs) run.RequireExited(deadline.RemainingMilliseconds);
            foreach (var run in runs) run.Close();
            StandaloneProcessJob.Close(job);
        }
        catch (Exception failure) { Retain(failure); }
    }

    private static void Retain(Exception failure)
    {
        // Fixture failures must not turn process exit into kill-on-close recovery.
        failure.Data[OwnershipRetention.RequiredKey] = true;
        try { Console.Out.WriteLine(OwnershipRetention.Sentinel); Console.Out.Flush(); }
        finally { Thread.Sleep(Timeout.Infinite); }
    }
}

public sealed class ShellScopeNativeSuite : IValidationSuite
{
    public string Id => "ownership.shell-scope-native";
    public IReadOnlyList<string> UnitIds => [Id];

    public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        string root = Path.Combine(context.ArtifactRoot, "shell-scope-native-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var result = await OwnedChildSupervisor.RunAsync(OwnedFixture.Command("shell-scope-regression", root),
            TimeSpan.FromSeconds(30), root, cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0 || !result.Cleanup.ResourcesClosed || !string.IsNullOrWhiteSpace(result.StandardError))
            throw new InvalidOperationException("Controlled shared-helper regression failed: " + result.StandardError);
        const string prefix = "SHELL_NATIVE_RESULT=";
        string[] reports = result.StandardOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => line.StartsWith(prefix, StringComparison.Ordinal)).ToArray();
        if (reports.Length != 1) throw new InvalidDataException("Expected one native scope fixture result.");
        using var report = JsonDocument.Parse(reports[0][prefix.Length..]);
        if (report.RootElement.GetProperty("executed").GetInt32() != ShellScopeNativeFixture.ExpectedCases ||
            report.RootElement.GetProperty("passed").GetInt32() != ShellScopeNativeFixture.ExpectedCases ||
            report.RootElement.GetProperty("failed").GetInt32() != 0)
            throw new InvalidDataException("Native shared-helper executed counts differ.");
        return [new UnitResult(Id, UnitStatus.Passed, ShellScopeNativeFixture.ExpectedCases,
            reports[0][prefix.Length..], ["controlled-native", "held-root-exit", "job-empty-not-process-signal"])];
    }
}
