using System.IO;
using GraphCode.Validation.Adapters;

namespace GraphCode.Validation.Host.RootContracts;

public static class SuiteRegistration
{
    public static IReadOnlyList<IValidationSuite> CreateSuites() =>
    [
        new RootSuite("host.hardening-source-and-diagnostics", "Host\\Hardening\\Diagnostics.ps1", HardeningCases,
            SourceContracts.Hardening, 7),
        new RootSuite("host.ci-partition", "Host\\CiContracts\\Partition.ps1", PartitionCases),
        new RootSuite("host.ci-aggregate", "Host\\CiContracts\\Aggregate.ps1", AggregateCases, SourceContracts.Aggregate, 8),
        new RootSuite("host.ci-topology", null, [], SourceContracts.Topology, 39),
        new RootSuite("host.shell-section-gate", "Host\\CiContracts\\ShellSections.ps1", SectionCases),
        new RootSuite("host.zig-resolver", "Host\\CiContracts\\ZigResolver.ps1", ResolverCases)
    ];

    private static readonly string[] HardeningCases =
    [
        "diagnostics.positions-and-bounds", "diagnostics.end-without-start", "diagnostics.empty-capture",
        "payload.complete.plain", "payload.complete.csi", "payload.complete.wrapped", "payload.complete.osc_bell",
        "payload.complete.osc_st_inside", "payload.complete.osc_st_outside",
        "payload.pending.empty", "payload.pending.missing_end", "payload.pending.missing_start",
        "payload.pending.reversed", "payload.pending.unterminated_osc", "payload.completed-empty"
    ];

    private static readonly string[] AggregateCases =
    [
        "required.success", "required.skipped", "required.failure", "required.cancelled", "not-required.skipped",
        "not-required.failure", "not-required.classifier-failure", "invalid-requirement", "empty-parts"
    ];

    private static readonly string[] PartitionCases =
    [
        "workflow.windows-shell.yml.shell-unit.0.0", "workflow.windows-shell.yml.shell-unit.0.1",
        "workflow.windows-shell.yml.shell-unit.0.2", "workflow.windows-shell.yml.shell-integration.0",
        "workflow.windows-shell.yml.shell-integration.1", "workflow.windows-shell.yml.packaging-contracts.0",
        "workflow.windows-shell.yml.packaging-real.0", "workflow.windows-port-validation.yml.investigation-privacy.0",
        "workflow.windows-port-validation.yml.spikes-swift.0", "workflow.windows-port-validation.yml.spikes-other.0",
        "workflow.windows-hardening.yml.deterministic.0", "coverage.all-listed-tasks", "coverage.all-parts",
        "control.complete", "control.missing-integration", "control.missing-unit-shard", "control.missing-packaging-real"
    ];

    private static readonly string[] SectionCases =
    [
        "section.reject.zero_all", "section.reject.failed", "section.reject.skipped_only",
        "section.positive-two-invocations", "section.reject.missing-second-summary", "section.reject.native-nonzero",
        "plan.unsharded-catalog", "plan.complete-disjoint-three-shards", "plan.workflow-agreement",
        "manifest.complete", "manifest.missing-section", "manifest.duplicate-section", "manifest.zero-tests",
        "manifest.skipped-assignment", "manifest.missing-shard"
    ];

    private static readonly string[] ResolverCases =
    [
        "probe.stdout-stderr-native-exit", "probe.launch-failure-nullable-exit", "resolver.configured-success",
        "resolver.fallback-order-deduplication", "resolver.native-exit-redacted-fallback",
        "resolver.env-exit.invalid", "resolver.env-zero-not-new-gate.invalid",
        "resolver.env-exit.json", "resolver.env-zero-not-new-gate.json",
        "resolver.launch-exception.version", "resolver.launch-exception.env",
        "resolver.writer-failure", "resolver.both-writers-fail", "resolver.both-writers-original-missing-guard",
        "diagnostic.unsafe-version.unicode.version", "diagnostic.unsafe-version.unicode.env",
        "diagnostic.unsafe-version.over_limit.version", "diagnostic.unsafe-version.over_limit.env",
        "diagnostic.candidate.userinfo", "diagnostic.candidate.secret", "diagnostic.candidate.over_limit"
    ];

    private sealed class RootSuite(
        string id, string? script, IReadOnlyList<string> cases,
        Func<string, UnitResult>? source = null, int sourceCount = 0) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => [id];

        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var rows = new List<UnitResult>();
            if (script is not null)
            {
                var adapter = new StandaloneSuites.CaseScriptSuite(id,
                    "Tools\\windows\\ValidationRunner\\" + script, "HOST_CASE_RESULT=", [id]);
                var observed = await adapter.RunAsync(context, cancellationToken);
                if (observed.Count != 1 || observed[0].Id != id)
                    throw new InvalidDataException($"{id}: expected exactly one matching adapter result");
                var row = observed[0];
                if (row.ExecutedCount != cases.Count || (row.Status == UnitStatus.Passed &&
                    (row.Groups is null || row.Groups.Count != cases.Count ||
                     !row.Groups.Order(StringComparer.Ordinal).SequenceEqual(cases.Order(StringComparer.Ordinal), StringComparer.Ordinal))))
                    row = row with { Status = UnitStatus.Failed, Evidence = row.Evidence + "; exact case inventory/count mismatch" };
                rows.Add(row);
            }
            if (source is not null)
            {
                var row = source(context.RepositoryRoot);
                if (row.Id != id || row.ExecutedCount != sourceCount)
                    row = row with { Status = UnitStatus.Failed, Evidence = row.Evidence + "; exact source case inventory/count mismatch" };
                rows.Add(row);
            }
            return [new UnitResult(id, rows.All(row => row.Status == UnitStatus.Passed) ? UnitStatus.Passed : UnitStatus.Failed,
                rows.Sum(row => row.ExecutedCount), string.Join("; ", rows.Select(row => row.Evidence)),
                rows.SelectMany(row => row.Groups ?? []).ToArray())];
        }
    }
}
