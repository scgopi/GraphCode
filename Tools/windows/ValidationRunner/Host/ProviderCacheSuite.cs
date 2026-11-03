using System.IO;
using System.Text.RegularExpressions;

namespace GraphCode.Validation.Host;

public sealed class ProviderCacheSuite : IValidationSuite
{
    private const string SaveCondition = "${{ !cancelled() && steps.bootstrap.conclusion == 'success' && steps.verify-pins.conclusion == 'success' && steps.provider-build.conclusion == 'success' && steps.provider-cache.outputs.cache-hit != 'true' }}";
    public string Id => "host.provider-cache";
    public IReadOnlyList<string> UnitIds => ["host.provider-cache-seeding", "host.provider-cache-mutations"];

    public Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var shell = File.ReadAllText(Path.Combine(context.RepositoryRoot, ".github", "workflows", "windows-shell.yml")).Replace("\r\n", "\n");
        var warmer = File.ReadAllText(Path.Combine(context.RepositoryRoot, ".github", "workflows", "windows-cache-warmer.yml")).Replace("\r\n", "\n");
        var rows = new List<UnitResult>();
        try { Verify(shell, warmer); }
        catch (InvalidDataException error)
        {
            rows.Add(new UnitResult(UnitIds[0], UnitStatus.Failed, 1, error.Message));
            return Task.FromResult<IReadOnlyList<UnitResult>>(rows);
        }
        rows.Add(new UnitResult(UnitIds[0], UnitStatus.Passed, 1, "Actual integration/warmer ordering, immutable key, read-only consumers and measured timeout guards"));
        var integration = Jobs(shell)["shell-integration"];
        var steps = Steps(integration);
        var save = steps.Single(step => step.Contains("actions/cache/save@", StringComparison.Ordinal));
        var gate = steps.Single(step => step.Contains("validate.ps1 -Task windows-shell", StringComparison.Ordinal));
        var build = steps.Single(step => Match(step, "(?m)^        id: provider-build\\s*$"));
        var changedIntegration = integration.Replace(save, "", StringComparison.Ordinal).Replace(gate, gate + save, StringComparison.Ordinal);
        var shellMutations = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["whole-job-success"] = shell.Replace(SaveCondition, "${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}", StringComparison.Ordinal),
            ["implicit-success"] = shell.Replace(SaveCondition, SaveCondition.Replace("!cancelled() && ", "", StringComparison.Ordinal), StringComparison.Ordinal),
            ["always"] = shell.Replace(SaveCondition, SaveCondition.Replace("!cancelled()", "always()", StringComparison.Ordinal), StringComparison.Ordinal),
            ["no-build-outcome"] = shell.Replace(SaveCondition, SaveCondition.Replace(" && steps.provider-build.conclusion == 'success'", "", StringComparison.Ordinal), StringComparison.Ordinal),
            ["resave-hit"] = shell.Replace(SaveCondition, SaveCondition.Replace(" && steps.provider-cache.outputs.cache-hit != 'true'", "", StringComparison.Ordinal), StringComparison.Ordinal),
            ["save-after-gate"] = shell.Replace(integration, changedIntegration, StringComparison.Ordinal),
            ["no-compile"] = shell.Replace(build, "", StringComparison.Ordinal),
            ["compile-replaced"] = shell.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build",
                "run: ./Tools/windows/bootstrap.ps1 -ToolRoot .ci-tools -ProviderRoot .ci-providers", StringComparison.Ordinal),
            ["partial-tree"] = shell.Replace(save, save.Replace("            .ci-tools/zig-global\n", "", StringComparison.Ordinal), StringComparison.Ordinal),
            ["continue-failure"] = shell.Replace(build, build.Replace("        shell: pwsh",
                "        continue-on-error: true\n        shell: pwsh", StringComparison.Ordinal), StringComparison.Ordinal),
            ["second-writer"] = shell.Replace("uses: actions/cache/restore@", "uses: actions/cache@", StringComparison.Ordinal)
        };
        var warmerMutations = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["warmer-terminal-tests"] = warmer.Replace("run: ./Tools/windows/validate.ps1 -Task provider-build",
                "run: ./Tools/windows/validate.ps1 -Task terminal-gate", StringComparison.Ordinal),
            ["warmer-success"] = warmer.Replace(SaveCondition, "${{ success() && steps.provider-cache.outputs.cache-hit != 'true' }}", StringComparison.Ordinal),
            ["warmer-bootstrap-cap"] = Regex.Replace(warmer, "(?s)(id: bootstrap.*?timeout-minutes: )\\d+", "${1}30", RegexOptions.CultureInvariant)
        };
        var executed = 0;
        try
        {
            foreach (var (name, mutation) in shellMutations)
            {
                Require(mutation != shell, $"Ineffective cache mutation: {name}");
                Refuse(mutation, warmer, name);
                executed++;
            }
            foreach (var (name, mutation) in warmerMutations)
            {
                Require(mutation != warmer, $"Ineffective warmer mutation: {name}");
                Refuse(shell, mutation, name);
                executed++;
            }
            rows.Add(new UnitResult(UnitIds[1], UnitStatus.Passed, executed, "Fourteen actual malformed workflow controls refused by the production-input oracle"));
        }
        catch (InvalidDataException error) { rows.Add(new UnitResult(UnitIds[1], UnitStatus.Failed, executed + 1, error.Message)); }
        return Task.FromResult<IReadOnlyList<UnitResult>>(rows);
    }

    private static void Refuse(string shell, string warmer, string name)
    {
        try { Verify(shell, warmer); }
        catch (InvalidDataException) { return; }
        throw new InvalidDataException($"Unsafe cache mutation admitted: {name}");
    }

    private static void Verify(string shell, string warmer)
    {
        var shellJobs = Jobs(shell);
        var warmerJobs = Jobs(warmer);
        Require(shellJobs.ContainsKey("shell-integration") && warmerJobs.ContainsKey("warm"), "Missing integration or warmer job");
        VerifyJob(shellJobs["shell-integration"], true);
        VerifyJob(warmerJobs["warm"], false);
        Require(Regex.Matches(shell, "actions/cache/save@", RegexOptions.CultureInvariant).Count == 1, "Integration must be the sole provider cache writer");
        foreach (var (name, job) in shellJobs)
        {
            if (name == "shell-integration") continue;
            foreach (var step in Steps(job))
                Require(!Match(step, "(?m)^\\s+\\.ci-providers\\s*$") || step.Contains("actions/cache/restore@", StringComparison.Ordinal),
                    $"Provider cache consumer is not read-only: {name}");
        }
        var warm = warmerJobs["warm"];
        var bootstrap = Number(warm, "(?s)id: bootstrap.*?timeout-minutes: (\\d+)");
        var build = Number(warm, "(?s)id: provider-build.*?timeout-minutes: (\\d+)");
        var outer = Number(warm, "(?m)^    timeout-minutes: (\\d+)\\s*$");
        Require(bootstrap >= 35 && outer > bootstrap + build, "Warmer caps truncate a healthy cold build");
        Require(Number(shellJobs["shell-integration"], "(?m)^    timeout-minutes: (\\d+)\\s*$") >= 41,
            "Integration cap truncates measured cold bootstrap, build, save and gate");
    }

    private static void VerifyJob(string job, bool requireGate)
    {
        var steps = Steps(job);
        int Find(params string[] patterns) => Array.FindIndex(steps, step => patterns.All(pattern => Match(step, pattern)));
        var restore = Find("(?m)^        id: provider-cache\\s*$", "actions/cache/restore@");
        var bootstrap = Find("(?m)^        id: bootstrap\\s*$", "(?m)^        run: \\./Tools/windows/bootstrap\\.ps1 ");
        var pins = Find("(?m)^        id: verify-pins\\s*$", "(?m)^        run: \\./Tools/windows/Assert-ProviderCheckout\\.ps1 -ProviderRoot \\.ci-providers\\s*$");
        var build = Find("(?m)^        id: provider-build\\s*$", "(?m)^        run: \\./Tools/windows/validate\\.ps1 -Task provider-build\\s*$");
        var saves = Enumerable.Range(0, steps.Length).Where(index => steps[index].Contains("actions/cache/save@", StringComparison.Ordinal)).ToArray();
        var gate = Find("(?m)^        run: \\./Tools/windows/validate\\.ps1 -Task windows-shell\\b");
        Require(restore >= 0 && bootstrap >= 0 && pins >= 0 && build >= 0 && saves.Length == 1, "Missing or duplicate cache stages");
        var save = saves[0];
        Require(restore < bootstrap && bootstrap < pins && pins < build && build < save &&
            (!requireGate || (gate >= 0 && save < gate)), "Provider cache save ordering is unsafe");
        var condition = Regex.Match(steps[save], "(?m)^        if:\\s*(.+?)\\s*$", RegexOptions.CultureInvariant);
        Require(condition.Success && condition.Groups[1].Value == SaveCondition, "Provider cache save must require explicit uncancelled bootstrap/pin/build success and a miss");
        Require(Match(steps[save], "(?m)^            \\.ci-providers\\s*$") &&
            Match(steps[save], "(?m)^            \\.ci-tools/zig-global\\s*$") &&
            Match(steps[save], "(?m)^          key: \\$\\{\\{ steps\\.provider-cache\\.outputs\\.cache-primary-key \\}\\}\\s*$"),
            "Provider cache save omits a required immutable tree or restored key");
        Require(!job.Contains("continue-on-error", StringComparison.Ordinal), "Provider build may not continue after a failure");
    }

    private static Dictionary<string, string> Jobs(string workflow)
    {
        var jobsAt = Regex.Match(workflow, "(?m)^jobs:\\s*$", RegexOptions.CultureInvariant);
        Require(jobsAt.Success, "Workflow has no jobs mapping");
        var body = workflow[(jobsAt.Index + jobsAt.Length)..];
        var heads = Regex.Matches(body, "(?m)^  ([A-Za-z0-9_-]+):[ \\t]*$", RegexOptions.CultureInvariant);
        Require(heads.Count > 0, "Workflow has no jobs");
        var jobs = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < heads.Count; index++)
        {
            var end = index + 1 < heads.Count ? heads[index + 1].Index : body.Length;
            Require(jobs.TryAdd(heads[index].Groups[1].Value, body[heads[index].Index..end]), "Workflow job is duplicated");
        }
        return jobs;
    }

    private static string[] Steps(string job)
    {
        var heads = Regex.Matches(job, "(?m)^      - ", RegexOptions.CultureInvariant);
        Require(heads.Count > 0, "Job has no steps");
        return Enumerable.Range(0, heads.Count).Select(index =>
        {
            var end = index + 1 < heads.Count ? heads[index + 1].Index : job.Length;
            return job[heads[index].Index..end];
        }).ToArray();
    }

    private static int Number(string text, string pattern)
    {
        var match = Regex.Match(text, pattern, RegexOptions.CultureInvariant);
        Require(match.Success, "Workflow timeout is missing");
        return int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
    }

    private static bool Match(string text, string pattern) => Regex.IsMatch(text, pattern, RegexOptions.CultureInvariant);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidDataException(message);
    }
}
