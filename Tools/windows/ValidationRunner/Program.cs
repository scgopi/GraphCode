using System.Reflection;
using System.Text.Json;
using GraphCode.Validation;
using GraphCode.Validation.Host;

if (args.SequenceEqual(new[] { "--self-test" })) return HostSelfTests.Run();

string? repositoryRoot = null;
string? artifactRoot = null;
string? selectedSuite = null;
for (var index = 0; index < args.Length; index++)
{
    if (index + 1 >= args.Length) throw new ArgumentException($"Missing value for {args[index]}");
    var value = args[++index];
    switch (args[index - 1])
    {
        case "--repository-root": repositoryRoot = Path.GetFullPath(value); break;
        case "--artifact-root": artifactRoot = Path.GetFullPath(value); break;
        case "--suite": selectedSuite = value; break;
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
    required = Coverage.Load(Path.Combine(AppContext.BaseDirectory, "Manifests"));
    foreach (var name in new[] { "GraphCode.Validation.Ui.SuiteRegistration", "GraphCode.Validation.Ownership.SuiteRegistration" })
    {
        var type = Assembly.GetExecutingAssembly().GetType(name);
        if (type is null) continue;
        var method = type.GetMethod("CreateSuites", BindingFlags.Public | BindingFlags.Static)
            ?? throw new InvalidDataException($"{name}.CreateSuites is missing");
        if (method.Invoke(null, null) is not IReadOnlyList<IValidationSuite> registered)
            throw new InvalidDataException($"{name}.CreateSuites has an invalid return type");
        suites.AddRange(registered);
    }
    if (selectedSuite is not null && suites.All(suite => suite.Id != selectedSuite))
        throw new ArgumentException($"No registered suite: {selectedSuite}");
    var context = new ValidationContext(repositoryRoot, artifactRoot);
    foreach (var suite in suites.Where(suite => selectedSuite is null || suite.Id == selectedSuite))
    {
        try { results.AddRange(await suite.RunAsync(context, CancellationToken.None)); }
        catch (Exception error)
        {
            errors.Add($"{suite.Id}: {error}");
            break;
        }
    }
}
catch (Exception error) { errors.Add(error.ToString()); }
var report = Coverage.Evaluate(required, suites, results, errors);
var reportPath = Path.Combine(artifactRoot, "coverage.json");
await File.WriteAllTextAsync(reportPath, JsonSerializer.Serialize(report, Coverage.JsonOptions));
foreach (var unit in report.Units)
    Console.WriteLine($"{unit.Status}: {unit.Id} executed={unit.ExecutedCount} {unit.Evidence}");
foreach (var error in report.Errors) Console.Error.WriteLine(error);
Console.WriteLine($"COVERAGE required={report.RequiredCount} passed={report.PassedCount} complete={report.Complete} report={reportPath}");
if (!report.Complete) return 1;
Console.WriteLine("CompiledValidationRunner: PASS");
Console.WriteLine("VALIDATION_RUNNER_EXECUTED=1");
return 0;
