using System.Reflection;
using System.IO;
using System.Text.Json;
using GraphCode.Validation;
using GraphCode.Validation.Host;
using GraphCode.Validation.Ownership;
using GraphCode.Validation.Adapters;

try { return await RunAsync(args); }
finally { await TerminalSafety.PreserveRetainedAuthorityAsync(OwnedChildSupervisor.RetainedLeaseCount); }

static async Task<int> RunAsync(string[] args)
{
    if (args.SequenceEqual(new[] { "--native-popup-effect-fixture" }))
        return GraphCode.Validation.Ui.NativeUiSuite.RunPopupEffects();
    if (HostFixture.TryRun(args) is int hostFixtureExit) return hostFixtureExit;
    if (await OwnedFixture.TryRunAsync(args) is int fixtureExit) return fixtureExit;
    if (args.SequenceEqual(new[] { "--self-test" })) return HostSelfTests.Run();

    string? repositoryRoot = null;
    string? artifactRoot = null;
    var selectedSuites = new HashSet<string>(StringComparer.Ordinal);
    for (var index = 0; index < args.Length; index++)
    {
        if (index + 1 >= args.Length) throw new ArgumentException($"Missing value for {args[index]}");
        var value = args[++index];
        switch (args[index - 1])
        {
            case "--repository-root": repositoryRoot = Path.GetFullPath(value); break;
            case "--artifact-root": artifactRoot = Path.GetFullPath(value); break;
            case "--suite":
                if (!selectedSuites.Add(value)) throw new ArgumentException($"Duplicate suite selector: {value}");
                break;
            default: throw new ArgumentException($"Unknown argument: {args[index - 1]}");
        }
    }
    if (repositoryRoot is null || artifactRoot is null)
        throw new ArgumentException("--repository-root and --artifact-root are required");
    if (!File.Exists(Path.Combine(repositoryRoot, "Tools", "windows", "validate.ps1")))
        throw new ArgumentException("Repository root must contain Tools\\windows\\validate.ps1");
    Directory.CreateDirectory(artifactRoot);
    var results = new List<UnitResult>();
    var suites = new List<IValidationSuite>();
    var errors = new List<string>();
    IReadOnlyList<RequiredUnit> required = [];
    try
    {
        var sourceDirectory = Path.Combine(repositoryRoot, "Tools", "windows", "ValidationRunner");
        required = Coverage.Load(Path.Combine(sourceDirectory, "Manifests"));
        suites.Add(HostSelfTests.CreateSuite());
        suites.AddRange(StandaloneSuites.Create(required));
        suites.Add(new ProviderCacheSuite());
        foreach (var name in new[]
        {
        "GraphCode.Validation.Ui.SuiteRegistration", "GraphCode.Validation.Ownership.SuiteRegistration",
        "GraphCode.Validation.Host.RootContracts.SuiteRegistration",
        "GraphCode.Validation.Host.RootContracts.ResidualScopeRegistration"
    })
        {
            var type = Assembly.GetExecutingAssembly().GetType(name);
            if (type is null) continue;
            var method = type.GetMethod("CreateSuites", BindingFlags.Public | BindingFlags.Static)
                ?? throw new InvalidDataException($"{name}.CreateSuites is missing");
            if (method.Invoke(null, null) is not IReadOnlyList<IValidationSuite> registered)
                throw new InvalidDataException($"{name}.CreateSuites has an invalid return type");
            suites.AddRange(registered);
        }
        foreach (var selection in selectedSuites)
            if (suites.All(suite => suite.Id != selection))
                throw new ArgumentException($"No registered suite: {selection}");
        var registryErrors = Coverage.RegistryErrors(required, suites);
        if (registryErrors.Count != 0)
            throw new InvalidDataException("Registry admission failed: " + string.Join("; ", registryErrors));
        var context = new ValidationContext(repositoryRoot, artifactRoot);
        foreach (var suite in suites.Where(suite => selectedSuites.Count == 0 || selectedSuites.Contains(suite.Id)))
        {
            try
            {
                var observations = await suite.RunAsync(context, CancellationToken.None);
                Coverage.ValidateProvenance(suite, observations);
                results.AddRange(observations);
                if (observations.Any(result => result.Status == UnitStatus.Failed))
                {
                    errors.Add($"{suite.Id}: a contract failed; subsequent suites were not executed");
                    break;
                }
            }
            catch (Exception error)
            {
                errors.Add($"{suite.Id}: {error}");
                Console.Error.WriteLine(ConsoleReport.SuiteFailure(suite.Id, error.GetType().FullName ?? error.GetType().Name));
                break;
            }
        }
    }
    catch (Exception error) { errors.Add(error.ToString()); }
    var report = Coverage.Evaluate(required, suites, results, errors,
        Path.Combine(repositoryRoot, "Tools", "windows", "ValidationRunner"));
    report = Coverage.ForInvocation(report, selectedSuites);
    var reportPath = Path.Combine(artifactRoot, "coverage.json");
    await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, Coverage.JsonOptions));
    foreach (var unit in report.Units)
        Console.WriteLine(ConsoleReport.Unit(unit));
    for (var index = 0; index < report.Errors.Count; index++) Console.Error.WriteLine(ConsoleReport.Error(index + 1));
    Console.WriteLine($"COVERAGE required={report.RequiredCount} passed={report.PassedCount} actualExecuted={report.ActualExecutedCount} derivedProofs={report.DerivedProofCount} complete={report.Complete} report={JsonSerializer.Serialize(reportPath)}");
    if (!report.Complete) return 1;
    Console.WriteLine("CompiledValidationRunner: PASS");
    Console.WriteLine("VALIDATION_RUNNER_EXECUTED=1");
    return 0;
}
