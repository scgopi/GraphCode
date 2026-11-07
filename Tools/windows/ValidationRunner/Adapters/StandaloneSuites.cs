using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using GraphCode.Validation.Host;

namespace GraphCode.Validation.Adapters;

public static class StandaloneSuites
{
    public static IReadOnlyList<IValidationSuite> Create(IReadOnlyList<RequiredUnit> required) =>
    [
        new ScriptSuite("ps.pester-version", "PesterVersion.Tests.ps1", EvidenceParser.PesterVersion),
        new ScriptSuite("ps.isolated-process-environment", "IsolatedProcessEnvironment.Contracts.Tests.ps1", EvidenceParser.IsolatedEnvironment),
        new ScriptSuite("ps.fixture-directory", "ValidationFixtureDirectory.Tests.ps1",
            output => EvidenceParser.Structured("ps.fixture-directory", "ValidationFixtureDirectory", output, 28, 28)),
        new ScriptSuite("ps.tray-admission", "TrayDaemon.Tests.ps1",
            output => EvidenceParser.Structured("ps.tray-admission", "TrayAdmission", output, 16, 16)),
        new ScriptSuite("ps.ui-scenario", "UiScenario.Tests.ps1",
            output => EvidenceParser.Structured("ps.ui-scenario", "UiScenario", output, 1, requireSkipped: false)),
        new CaseScriptSuite("ui.cards-pilot-contracts", "Tools\\windows\\ValidationRunner\\Ui\\CardsPilotContracts.ps1",
            "UI_CASE_RESULT=", required.Where(unit => unit.Id.StartsWith("ui.cards-pilot.", StringComparison.Ordinal))
                .Select(unit => unit.Id).ToArray()),
        new CaptureSuite(required.Single(unit => unit.Id == "ps.ui-capture")),
        new ScriptSuite("ps.action-worker", "ActionWorkerImport.Tests.ps1",
            output => EvidenceParser.Structured("ps.action-worker", "ActionWorkerImport", output, 20, 20)),
        new ScriptSuite("ps.action-identity", "ActionWindowIdentity.Tests.ps1",
            output => EvidenceParser.Structured("ps.action-identity", "ActionWindowIdentity", output, 85, 85)),
        new ScriptSuite("ps.action-topology", "ActionTopologyImport.Tests.ps1",
            output => EvidenceParser.Structured("ps.action-topology", "ActionTopologyImport", output, 16, 16)),
        new ScriptSuite("ps.wire-targeting", "WireTargeting.Tests.ps1",
            output => EvidenceParser.Structured("ps.wire-targeting", "WireTargeting", output, 75, 75)),
        new ScriptSuite("ps.agent-command", "Invoke-AgentCommand.Tests.ps1", EvidenceParser.AgentCommand),
        new HostTaskSuite("host.task-inventory", "inventory", 17),
        new HostTaskSuite("host.task-dry-run", "dry-run", 7),
        new HostTaskSuite("host.unknown-task", "unknown", 1),
        new HostTaskSuite("host.foreign-fixture", "foreign-fixture", 1),
        new HostTaskSuite("host.untracked-format", "untracked-format", 1),
        new HostTaskSuite("host.missing-providers", "missing-providers", 1),
        new HostSourceSuite("host.shell-prerequisite", "host-prerequisite", 4),
        new HostSourceSuite("host.provider-task-boundary", "provider-boundary", 5),
        new HostSourceSuite("ui.root.source.line-5346", "delayed-responses", 2),
        new CaseScriptSuite("host.provenance", "Tools\\windows\\ValidationRunner\\Adapters\\Provenance.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.provenance.current-source", "host.provenance.source-changed", "host.provenance.source-restored"]),
        new CaseScriptSuite("host.provider-build", "Tools\\windows\\ValidationRunner\\Adapters\\ProviderBuild.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.provider-build"]),
        new CaseScriptSuite("host.legacy-ownership.shell-scope", "Tools\\windows\\ValidationRunner\\Adapters\\LegacyOwnership.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.legacy-ownership.shell-scope"], ["-Contract", "shell-scope"]),
        new CaseScriptSuite("host.legacy-ownership.live-adapter", "Tools\\windows\\ValidationRunner\\Adapters\\LegacyOwnership.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.legacy-ownership.live-adapter"], ["-Contract", "live-adapter"]),
        new CaseScriptSuite("host.compiled-assembly-environment", "Tools\\windows\\ValidationRunner\\Adapters\\LegacyOwnership.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.compiled-assembly-environment"], ["-Contract", "compiled-environment"]),
        new CaseScriptSuite("host.legacy-ownership.live-cleanup", "Tools\\windows\\ValidationRunner\\Adapters\\LegacyOwnership.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.legacy-ownership.live-cleanup"], ["-Contract", "live-cleanup"]),
        new CaseScriptSuite("host.sdk-prerequisites", "Tools\\windows\\ValidationRunner\\Adapters\\LegacyOwnership.Contracts.ps1",
            "HOST_CASE_RESULT=", ["host.sdk-prerequisites"], ["-Contract", "sdk-prerequisites"]),
        new CaseScriptSuite("ui.source-contracts", "Tools\\windows\\ValidationRunner\\Ui\\UiSourceContracts.ps1",
            "UI_CASE_RESULT=", required.Where(unit => unit.Id.StartsWith("ui.activation.source.", StringComparison.Ordinal) ||
                unit.Id.StartsWith("ui.popup.source.", StringComparison.Ordinal)).Select(unit => unit.Id).ToArray())
    ];

    private sealed class ScriptSuite(string id, string script, Func<string, UnitResult> parse) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => [id];
        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            var output = await PowerShellPayload.RunAsync(context, id, "Tools\\windows\\Tests\\" + script, [], cancellationToken);
            var result = parse(output.Output);
            return [WithReceipt(result, output)];
        }
    }

    private sealed class HostTaskSuite(string id, string contract, int count) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => [id];
        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            var output = await PowerShellPayload.RunAsync(context, id,
                "Tools\\windows\\ValidationRunner\\Adapters\\HostTasks.ps1",
                ["-RepositoryRoot", context.RepositoryRoot, "-Contract", contract], cancellationToken);
            return [WithReceipt(EvidenceParser.Structured(id, "HostTasks." + contract, output.Output, count, count), output)];
        }

    }

    private sealed class HostSourceSuite(string id, string contract, int count) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => [id];
        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            var output = await PowerShellPayload.RunAsync(context, id,
                "Tools\\windows\\ValidationRunner\\Adapters\\HostSourceContracts.ps1",
                ["-RepositoryRoot", context.RepositoryRoot, "-Contract", contract], cancellationToken);
            return [WithReceipt(EvidenceParser.Structured(id, "HostSource." + contract, output.Output, count, count), output)];
        }
    }

    private sealed class CaptureSuite(RequiredUnit required) : IValidationSuite
    {
        public string Id => "ps.ui-capture";
        public IReadOnlyList<string> UnitIds => [Id];
        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            const string script = "Tools\\windows\\Tests\\UiCaptureDriver.Tests.ps1";
            var captureRoot = PowerShellPayload.CreateScratchRoot(context.RepositoryRoot);
            await File.WriteAllTextAsync(Path.Combine(context.ArtifactRoot, "capture-root.txt"), captureRoot, cancellationToken);
            var prebuilt = Path.Combine(captureRoot, "prebuilt");
            var compilerContracts = await PowerShellPayload.RunAsync(context, Id + ".compiler-input",
                "Tools\\windows\\Tests\\FixtureCompiler.Tests.ps1",
                ["-ScratchRoot", Path.Combine(captureRoot, "compiler-contracts")], cancellationToken);
            if (EvidenceParser.Structured(Id, "FixtureCompiler", compilerContracts.Output, 27, 27).Status != UnitStatus.Passed)
                throw new InvalidDataException("Fixture compiler input contracts failed");
            var hierarchyContracts = await PowerShellPayload.RunAsync(context, Id + ".window-hierarchy-diagnostic",
                "Tools\\windows\\Tests\\WindowHierarchyDiagnostic.Tests.ps1",
                ["-ScratchRoot", Path.Combine(captureRoot, "window-hierarchy-contracts")], cancellationToken);
            if (EvidenceParser.Structured(Id, "WindowHierarchyDiagnostic", hierarchyContracts.Output, 32, 32).Status != UnitStatus.Passed)
                throw new InvalidDataException("Window hierarchy diagnostic contracts failed");
            string[] compilerArguments = context.FixtureCompilerInput is null ? [] :
                ["-FixtureCompilerInput", context.FixtureCompilerInput,
                 "-FixtureCompilerInputSha256", context.FixtureCompilerInputSha256!];
            await PowerShellPayload.RunAsync(context, Id + ".prepare", script,
                ["-PrepareFixturesOnly", "-ScratchRoot", prebuilt, .. compilerArguments], cancellationToken);
            var manifest = Path.Combine(prebuilt, "fixtures.json");
            var hash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(manifest, cancellationToken)));
            var suiteRoot = Path.Combine(captureRoot, "suite");
            var output = await PowerShellPayload.RunAsync(context, Id, script,
                ["-ScratchRoot", suiteRoot, "-PrebuiltFixtureManifest", manifest, "-PrebuiltFixtureManifestSha256", hash],
                cancellationToken, value => EvidenceParser.CaptureDiagnostics(value, suiteRoot));
            var result = WithReceipt(EvidenceParser.Structured(Id, "UiCaptureDriver", output.Output, 182, 182), output);
            return [result with { Groups = EvidenceParser.CaptureGroups(Path.Combine(suiteRoot, "report.json"),
                required.RequiredGroups ?? []) }];
        }
    }

    public sealed class CaseScriptSuite(string id, string script, string prefix, IReadOnlyList<string> unitIds,
        IReadOnlyList<string>? additionalArguments = null) : IValidationSuite
    {
        public string Id => id;
        public IReadOnlyList<string> UnitIds => unitIds;
        public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
        {
            var output = await PowerShellPayload.RunAsync(context, id, script,
                ["-RepositoryRoot", context.RepositoryRoot, "-ArtifactRoot", context.ArtifactRoot,
                 "-AssemblyPath", Assembly.GetExecutingAssembly().Location, .. additionalArguments ?? []], cancellationToken);
            var rows = output.Output.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries)
                .Where(line => line.StartsWith(prefix, StringComparison.Ordinal)).Select(line =>
                    JsonSerializer.Deserialize<UnitResult>(line[prefix.Length..], Coverage.JsonOptions) ??
                    throw new InvalidDataException($"{id}: null case evidence")).ToArray();
            if (rows.Length == 0) throw new InvalidDataException($"{id}: no case evidence");
            return rows.Select(result => result with
            {
                Evidence = $"Case evidence retained in payload logs; evidence-text-sha256=" +
                    Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(result.Evidence))) +
                    $"; stdout-text-sha256={output.StdoutTextSha256}; artifacts={output.ArtifactRoot}"
            }).ToArray();
        }
    }

    private static UnitResult WithReceipt(UnitResult result, PowerShellPayload.Receipt receipt) => result with
    {
        Evidence = $"{result.Evidence}; stdout-text-sha256={receipt.StdoutTextSha256}; artifacts={receipt.ArtifactRoot}"
    };
}
