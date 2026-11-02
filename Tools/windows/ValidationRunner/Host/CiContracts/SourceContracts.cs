using System.IO;
using System.Text.RegularExpressions;

namespace GraphCode.Validation.Host.RootContracts;

internal sealed class SourceCases
{
    private readonly List<(string Id, string? Error)> results = [];

    internal void Check(string id, Action body)
    {
        try { body(); results.Add((id, null)); }
        catch (Exception error) when (error is InvalidDataException or ArgumentException or KeyNotFoundException)
        { results.Add((id, error.Message)); }
    }

    internal UnitResult Result(string id)
    {
        var failed = results.Where(row => row.Error is not null).ToArray();
        return new UnitResult(id, failed.Length == 0 ? UnitStatus.Passed : UnitStatus.Failed, results.Count,
            $"Typed source contracts: executed={results.Count}; failed={failed.Length}" +
            string.Concat(failed.Select(row => $"; {row.Id}: {row.Error}")),
            results.Where(row => row.Error is null).Select(row => row.Id).ToArray());
    }

    internal static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidDataException(message);
    }

    internal static bool Match(string text, string pattern) =>
        Regex.IsMatch(text, pattern, RegexOptions.CultureInvariant, TimeSpan.FromSeconds(2));
}

internal sealed class WorkflowText
{
    internal string Text { get; }
    internal IReadOnlyDictionary<string, string> Jobs { get; }

    internal WorkflowText(string text)
    {
        Text = text.Replace("\r\n", "\n", StringComparison.Ordinal);
        var start = Regex.Match(Text, @"(?m)^jobs:[ \t]*$", RegexOptions.CultureInvariant);
        SourceCases.Require(start.Success, "Workflow has no jobs mapping");
        var body = Text[(start.Index + start.Length)..];
        var headings = Regex.Matches(body, @"(?m)^  ([A-Za-z0-9_-]+):[ \t]*$", RegexOptions.CultureInvariant);
        var jobs = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < headings.Count; index++)
        {
            var end = index + 1 < headings.Count ? headings[index + 1].Index : body.Length;
            SourceCases.Require(jobs.TryAdd(headings[index].Groups[1].Value,
                body[headings[index].Index..end]), "Workflow repeats a job identifier");
        }
        SourceCases.Require(jobs.Count > 0, "Workflow jobs mapping is empty");
        Jobs = jobs;
    }

    internal static IReadOnlyList<string> Steps(string job) =>
        Regex.Matches(job, @"(?ms)^      - .*?(?=^      - |\z)", RegexOptions.CultureInvariant)
            .Select(match => match.Value).ToArray();
}

internal static class SourceContracts
{
    internal static UnitResult Hardening(string root)
    {
        var cases = new SourceCases();
        var hardening = File.ReadAllText(Path.Combine(root, "Tools", "windows", "Tests", "Hardening.Tests.ps1"));
        var workflow = File.ReadAllText(Path.Combine(root, ".github", "workflows", "windows-hardening.yml"));
        cases.Check("source.full-pinned-real-hardening", () => SourceCases.Require(SourceCases.Match(workflow,
            @"(?s)full-pinned:.*bootstrap\.ps1.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment"),
            "Full pinned CI must run real hardening after provider setup"));
        cases.Check("source.owned-environment", () => SourceCases.Require(workflow.Contains("GRAPHCODE_HARDENING_TARGET",
            StringComparison.Ordinal), "Full pinned CI must supply an owned environment harness"));
        foreach (var stage in new[] { "real zmx/ConPTY terminal matrix", "real GraphCode shell matrix" })
            cases.Check("source.native-exit." + (stage.Contains("zmx", StringComparison.Ordinal) ? "terminal" : "shell"),
                () => SourceCases.Require(SourceCases.Match(hardening,
                    Regex.Escape(stage) + @" failed \(exit=\$LASTEXITCODE; hex="), "Native stage failure lost exit/hex diagnostics"));
        cases.Check("source.high-output-failure-diagnostics", () => SourceCases.Require(SourceCases.Match(hardening,
            @"(?s)if \(-not \$completed\).*?Get-HighOutputDiagnostics.*?HARDENING_OUTPUT_DIAGNOSTICS_JSON=.*?Assert-True \$completed"),
            "High-output failure lost bounded transcript diagnostics"));
        cases.Check("source.repeat-preserves-child-diagnostics", () => SourceCases.Require(SourceCases.Match(hardening,
            "(?s)if \\(\\$LASTEXITCODE -ne 0\\) \\{\\s*\\$output \\| Write-Output\\s*throw \"hardening repeated run"),
            "Failed repeated hardening discards child diagnostics"));
        cases.Check("source.release-shell-version", () => SourceCases.Require(SourceCases.Match(hardening,
            @"(?s)\$shellVersion\s*=\s*\(& \$shell --version.*?-Version \$shellVersion"),
            "Post-release hardening lost the built shell version"));
        return cases.Result("host.hardening-source-and-diagnostics");
    }

    internal static UnitResult Aggregate(string root)
    {
        var cases = new SourceCases();
        foreach (var (file, id, exempt) in new[]
        {
            ("windows-shell.yml", "windows-shell", Array.Empty<string>()),
            ("windows-port-validation.yml", "windows-spikes", new[] { "investigation-privacy" })
        })
        {
            var workflow = new WorkflowText(File.ReadAllText(Path.Combine(root, ".github", "workflows", file)));
            cases.Check("source.aggregate." + id, () => AssertAggregate(workflow, id, exempt));
        }
        var fixture = """
            jobs:
              changes:
                runs-on: ubuntu-latest
              part:
                runs-on: windows-2022
              gate:
                needs: [changes, part]
                if: ${{ !cancelled() }}
                env:
                  NEEDS_JSON: ${{ toJSON(needs) }}
                steps:
                  - run: ./Tools/windows/Assert-CiPartResults.ps1 -NeedsJson $env:NEEDS_JSON -Required $env:WINDOWS_REQUIRED
            """.Replace("\r\n", "\n", StringComparison.Ordinal);
        cases.Check("control.aggregate.valid", () => AssertAggregate(new WorkflowText(fixture), "gate", []));
        foreach (var (id, before, after) in new[]
        {
            ("missing-part", "[changes, part]", "[changes]"),
            ("renamed-required-check", "  gate:\n", "  gate:\n    name: renamed\n"),
            ("success-only", "${{ !cancelled() }}", "${{ success() }}"),
            ("missing-needs-json", "NEEDS_JSON:", "UNUSED_JSON:"),
            ("missing-required-argument", " -Required $env:WINDOWS_REQUIRED", "")
        })
        {
            cases.Check("control.aggregate." + id, () =>
            {
                var mutant = Mutate(fixture, before, after);
                Reject(() => AssertAggregate(new WorkflowText(mutant), "gate", []));
            });
        }
        return cases.Result("host.ci-aggregate");
    }

    private static void AssertAggregate(WorkflowText workflow, string id, IReadOnlyList<string> exempt)
    {
        var aggregate = workflow.Jobs[id];
        SourceCases.Require(!SourceCases.Match(aggregate, @"(?m)^    name:"),
            "Required aggregate must retain its job ID as its check name");
        var match = Regex.Match(aggregate, @"(?m)^    needs:\s*\[([^\]]+)\]", RegexOptions.CultureInvariant);
        SourceCases.Require(match.Success, "Aggregate does not declare needed parts");
        var needed = match.Groups[1].Value.Split(',').Select(value => value.Trim()).ToArray();
        SourceCases.Require(workflow.Jobs.Keys.All(name => name == id || exempt.Contains(name) || needed.Contains(name)),
            "Aggregate does not wait for every non-exempt part");
        SourceCases.Require(SourceCases.Match(aggregate, @"(?m)^    if: \$\{\{ !cancelled\(\) \}\}\s*$") &&
            aggregate.Contains("NEEDS_JSON: ${{ toJSON(needs) }}", StringComparison.Ordinal) &&
            aggregate.Contains("Assert-CiPartResults.ps1 -NeedsJson $env:NEEDS_JSON -Required $env:WINDOWS_REQUIRED", StringComparison.Ordinal),
            "Aggregate must fail closed over every part");
    }

    internal static UnitResult Topology(string root)
    {
        var cases = new SourceCases();
        var directory = Path.Combine(root, ".github", "workflows");
        var port = new WorkflowText(File.ReadAllText(Path.Combine(directory, "windows-port-validation.yml")));
        var shell = new WorkflowText(File.ReadAllText(Path.Combine(directory, "windows-shell.yml")));
        var hardening = new WorkflowText(File.ReadAllText(Path.Combine(directory, "windows-hardening.yml")));
        var warmer = new WorkflowText(File.ReadAllText(Path.Combine(directory, "windows-cache-warmer.yml")));
        foreach (var (workflow, id, cap, steps) in new[]
        {
            (port, "spikes-swift", 45, 5), (port, "spikes-other", 40, 6), (shell, "packaging-real", 50, 6)
        })
        {
            cases.Check("source.cold-cache." + id, () =>
            {
                var text = workflow.Jobs[id];
                SourceCases.Require(SourceCases.Match(text, $@"(?m)^    timeout-minutes: {cap}\s*$") &&
                    Regex.Matches(text, @"(?m)^        timeout-minutes: \d+\s*$").Count >= steps &&
                    SourceCases.Match(text, @"(?s)name: Bootstrap exact Windows dependencies.*?timeout-minutes: 30"),
                    "Measured cold-cache job/step/bootstrap headroom was removed");
            });
        }
        cases.Check("source.runner-topology-timeout", () =>
        {
            var step = WorkflowText.Steps(port.Jobs["spikes-swift"])
                .SingleOrDefault(text => text.Contains("name: Verify validation runner contract", StringComparison.Ordinal)) ?? "";
            var cap = Regex.Match(step, @"(?m)^        timeout-minutes: (\d+)\s*$");
            SourceCases.Require(cap.Success && int.Parse(cap.Groups[1].Value,
                System.Globalization.CultureInfo.InvariantCulture) >= 12, "Runner topology step lost measured timeout headroom");
        });
        foreach (var key in new[]
        {
            "windows-zig-v1-${{ hashFiles('Tools/windows/bootstrap.ps1') }}",
            "windows-providers-v1-${{ hashFiles('graphcode-windows/provider-pins.json', 'Tools/windows/bootstrap.ps1') }}-emit-win32-host-x86_64-windows-gnu"
        })
            cases.Check("source.warmer-key." + (key.Contains("providers", StringComparison.Ordinal) ? "providers" : "zig"),
                () => SourceCases.Require(warmer.Text.Contains(key, StringComparison.Ordinal), "Warmer does not seed the production immutable key"));
        cases.Check("source.warmer-events-and-build-only", () => SourceCases.Require(
            SourceCases.Match(warmer.Text, @"(?m)^  push:\s*$") &&
            SourceCases.Match(warmer.Text, @"(?m)^    branches: \[main\]\s*$") &&
            SourceCases.Match(warmer.Text, @"(?m)^  schedule:\s*$") &&
            SourceCases.Match(warmer.Text, "(?m)^    - cron: \"23 4 \\* \\* 1\"\\s*$") &&
            SourceCases.Match(warmer.Text, @"(?m)^  workflow_dispatch:\s*$") &&
            SourceCases.Match(warmer.Text, @"(?s)validate\.ps1 -Task provider-build.*?actions/cache/save@") &&
            !warmer.Text.Contains("validate.ps1 -Task terminal-gate", StringComparison.Ordinal),
            "Warmer lost main/weekly/manual events or build-only execution"));
        foreach (var (name, workflow) in new[] { ("shell", shell), ("port", port) })
            cases.Check("source.uia-diagnostics." + name, () => SourceCases.Require(SourceCases.Match(workflow.Text,
                @"(?s)if: failure\(\).*?actions/upload-artifact@.*?gu-\*.*?logs\\\*\.json"), "Failed UIA diagnostics are not retained"));
        foreach (var (name, workflow) in new[] { ("shell", shell), ("port", port), ("hardening", hardening) })
            cases.Check("source.pinned-swift." + name, () => SourceCases.Require(
                workflow.Text.Contains("compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6", StringComparison.Ordinal) &&
                workflow.Text.Contains("swift-version: swift-6.3.3-release", StringComparison.Ordinal) &&
                workflow.Text.Contains("swift-build: 6.3.3-RELEASE", StringComparison.Ordinal), "Pinned Swift setup changed"));
        cases.Check("source.shell-bootstrap", () => SourceCases.Require(shell.Text.Contains("bootstrap.ps1", StringComparison.Ordinal),
            "Shell CI no longer bootstraps pinned dependencies"));
        cases.Check("source.hosted-explicit-skip-limits", () => SourceCases.Require(
            shell.Text.Contains("validate.ps1 -Task windows-shell -SkipTrayLive", StringComparison.Ordinal) &&
            port.Text.Contains("validate.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E", StringComparison.Ordinal) &&
            hardening.Text.Contains("validate.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E", StringComparison.Ordinal) &&
            hardening.Text.Contains("Hardening.Tests.ps1 -Environment -SkipTrayLive", StringComparison.Ordinal),
            "Hosted CI must explicitly declare unsupported tray/WSL fixtures"));
        cases.Check("source.shell-live-task", () => SourceCases.Require(SourceCases.Match(shell.Text,
            @"(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 -Task windows-shell\b"), "Shell CI no longer invokes its live task"));
        cases.Check("source.runner-single-win2022-fail-closed", () =>
        {
            var job = port.Jobs["validation-runner"];
            SourceCases.Require(SourceCases.Match(job, @"(?m)^    needs: changes\s*$") &&
                job.Contains("needs.changes.outputs.windows == 'true'", StringComparison.Ordinal) &&
                job.Contains("needs.changes.result != 'success'", StringComparison.Ordinal) &&
                SourceCases.Match(job, @"(?m)^    runs-on: windows-2022\s*$") &&
                !SourceCases.Match(job, @"(?m)^\s+(strategy|matrix):"), "Dedicated runner job must execute once with the fail-closed Windows path gate");
        });
        cases.Check("source.runner-no-providers-or-hidden-failure", () => SourceCases.Require(
            !SourceCases.Match(port.Jobs["validation-runner"], @"bootstrap\.ps1|\.ci-providers|continue-on-error"),
            "Source-only runner job must not bootstrap providers or hide failure"));
        cases.Check("source.runner-new-sdk-build-execution", () => AssertCanonicalJob(port.Jobs["validation-runner"]));
        cases.Check("source.runner-port-exactly-once", () => SourceCases.Require(ExeInvocations(port.Text) == 1 &&
            !SourceCases.Match(port.Jobs["spikes-swift"], @"ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1|ValidationRunner\.exe"),
            "Port workflow must execute the full compiled runner exactly once, never the legacy program"));
        cases.Check("source.runner-aggregate-required", () => SourceCases.Require(SourceCases.Match(port.Jobs["windows-spikes"],
            @"(?m)^    needs: \[changes, validation-runner, spikes-swift, spikes-other\]\s*$"),
            "Required aggregate must include the dedicated compiled runner"));
        cases.Check("source.runner-hardening-single-fallback", () =>
        {
            var candidates = WorkflowText.Steps(hardening.Jobs["deterministic"])
                .Where(step => ExeInvocations(step) > 0).ToArray();
            SourceCases.Require(candidates.Length == 1 && ExeInvocations(hardening.Text) == 1 &&
                candidates[0].Contains("env.HARDENING_REQUIRED == 'true'", StringComparison.Ordinal) &&
                candidates[0].Contains("github.event_name != 'pull_request'", StringComparison.Ordinal) &&
                candidates[0].Contains("matrix.os == 'windows-2022'", StringComparison.Ordinal),
                "Hardening must keep one non-PR Windows 2022 fallback without duplicate PR execution");
            AssertCanonicalJob(hardening.Jobs["deterministic"]);
        });
        cases.Check("source.runner-compatibility-no-monolith", () =>
        {
            var wrapper = File.ReadAllText(Path.Combine(root, "Tools", "windows", "Invoke-ValidationRunnerContract.ps1"));
            SourceCases.Require(wrapper.Contains("ValidationRunner.exe", StringComparison.Ordinal) &&
                !wrapper.Contains("ValidationRunner.Tests.ps1", StringComparison.Ordinal),
                "Compatibility entry must execute only the compiled host, never the old monolith");
            AssertProof(wrapper);
        });
        AddCanonicalControls(cases);
        return cases.Result("host.ci-topology");
    }

    internal static int ExeInvocations(string text) => Regex.Matches(text,
        @"(?m)^\s*(?:run:\s*)?\.\\Tools\\windows\\ValidationRunner\\bin\\Release\\net10\.0-windows\\ValidationRunner\.exe --repository-root \$PWD --artifact-root \.ci-validation-runner[ \t]*$").Count;

    private static void AssertCanonicalJob(string job)
    {
        SourceCases.Require(SourceCases.Match(job, @"uses: actions/setup-dotnet@") &&
            SourceCases.Match(job, @"(?m)^\s+dotnet-version: ['""]?10\.0\.403['""]?[ \t]*$"), "Compiled host requires the exact .NET SDK");
        var build = WorkflowText.Steps(job).Where(step => SourceCases.Match(step, @"(?m)^\s+dotnet build -c Release[ \t]*$")).ToArray();
        SourceCases.Require(build.Length == 1 && SourceCases.Match(build[0],
            @"(?m)^        working-directory: Tools/windows/ValidationRunner[ \t]*$") &&
            build[0].Contains("dotnet --version", StringComparison.Ordinal) &&
            build[0].Contains("10.0.403", StringComparison.Ordinal), "Host build must select global.json from the nested project directory and assert its SDK");
        SourceCases.Require(ExeInvocations(job) == 1 &&
            !SourceCases.Match(job, @"--suite\b|--self-test\b|--fixture\b|ValidationRunner\.Tests\.ps1|Invoke-ValidationRunnerContract\.ps1"),
            "CI must execute exactly one normal full compiled host, not a filtered/self-test/legacy entry");
        AssertProof(job);
    }

    private static void AssertProof(string text)
    {
        SourceCases.Require(text.Contains("coverage.json", StringComparison.Ordinal) &&
            SourceCases.Match(text, @"(?i)-not\s+\$[A-Za-z][A-Za-z0-9_]*\.complete\b") &&
            SourceCases.Match(text, @"(?i)\$[A-Za-z][A-Za-z0-9_]*\.requiredCount\s+(?:-le\s+0|-lt\s+1)") &&
            SourceCases.Match(text, @"(?i)\$([A-Za-z][A-Za-z0-9_]*)\.passedCount\s+-ne\s+\$\1\.requiredCount\b") &&
            text.Contains("CompiledValidationRunner: PASS", StringComparison.Ordinal) &&
            text.Contains("VALIDATION_RUNNER_EXECUTED=1", StringComparison.Ordinal) &&
            SourceCases.Match(text, @"(?i)\$exitCode\s+-ne\s+0|\$LASTEXITCODE\s+-ne\s+0") &&
            SourceCases.Match(text, @"(?i)\$passMarkers\s+-ne\s+1") &&
            SourceCases.Match(text, @"(?i)\$executedMarkers\s+-ne\s+1"),
            "Normal execution must prove exit zero, one full PASS/count marker, complete coverage and positive required/passed counts");
    }

    private static void AddCanonicalControls(SourceCases cases)
    {
        var fixture = """
              runner:
                steps:
                  - uses: actions/setup-dotnet@pinned
                    with:
                      dotnet-version: 10.0.403
                  - name: Build compiled host
                    working-directory: Tools/windows/ValidationRunner
                    run: |
                      if ((dotnet --version) -ne '10.0.403') { throw 'SDK' }
                      dotnet build -c Release
                  - name: Run compiled host
                    run: |
                      .\Tools\windows\ValidationRunner\bin\Release\net10.0-windows\ValidationRunner.exe --repository-root $PWD --artifact-root .ci-validation-runner
                      $exitCode = $LASTEXITCODE
                      if ($exitCode -ne 0) { throw 'exit' }
                      $report = Get-Content .ci-validation-runner\coverage.json | ConvertFrom-Json
                      if (-not $report.complete -or $report.requiredCount -le 0 -or $report.passedCount -ne $report.requiredCount) { throw 'coverage' }
                      $passMarkers = @($output | Where-Object { $_ -ceq 'CompiledValidationRunner: PASS' }).Count
                      $executedMarkers = @($output | Where-Object { $_ -ceq 'VALIDATION_RUNNER_EXECUTED=1' }).Count
                      if ($passMarkers -ne 1 -or $executedMarkers -ne 1) { throw 'markers' }
            """.Replace("\r\n", "\n", StringComparison.Ordinal);
        cases.Check("control.canonical.valid", () => AssertCanonicalJob(fixture));
        foreach (var (id, before, after) in new[]
        {
            ("wrong-sdk", "dotnet-version: 10.0.403", "dotnet-version: 10.0.x"),
            ("wrong-build-cwd", "working-directory: Tools/windows/ValidationRunner", "working-directory: ."),
            ("filtered-run", "--artifact-root .ci-validation-runner", "--artifact-root .ci-validation-runner --suite ui.activation"),
            ("missing-run", @".\Tools\windows\ValidationRunner\bin\Release\net10.0-windows\ValidationRunner.exe", "Write-Output"),
            ("missing-complete", "$report.complete", "$report.unused"),
            ("missing-positive-count", "$report.requiredCount -le 0", "$report.requiredCount -le -1"),
            ("missing-full-count-equality", "$report.passedCount -ne $report.requiredCount", "$report.passedCount -lt 0"),
            ("inverted-complete", "-not $report.complete", "$report.complete"),
            ("missing-pass-count", "$passMarkers -ne 1", "$passMarkers -ne 0"),
            ("missing-executed-count", "$executedMarkers -ne 1", "$executedMarkers -ne 0"),
            ("ignored-exit", "$exitCode -ne 0", "$exitCode -ne 1")
        })
            cases.Check("control.canonical." + id, () =>
            {
                var mutant = Mutate(fixture, before, after);
                Reject(() => AssertCanonicalJob(mutant));
            });
        cases.Check("control.canonical.duplicate-run", () => Reject(() => AssertCanonicalJob(fixture +
            "\n          .\\Tools\\windows\\ValidationRunner\\bin\\Release\\net10.0-windows\\ValidationRunner.exe --repository-root $PWD --artifact-root .ci-validation-runner\n")));
    }

    private static void Reject(Action body)
    {
        var rejected = false;
        try { body(); } catch (InvalidDataException) { rejected = true; }
        SourceCases.Require(rejected, "Deliberate negative control was accepted");
    }

    private static string Mutate(string text, string before, string after)
    {
        var mutant = text.Replace(before, after, StringComparison.Ordinal);
        SourceCases.Require(mutant != text, "Negative control did not change its fixture");
        return mutant;
    }
}
