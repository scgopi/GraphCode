using System.Text.Json;
using System.IO;
using System.Text.Json.Serialization;

namespace GraphCode.Validation.Host;

public sealed record RequiredUnit(
    string Id, string Owner, int MinimumCount, IReadOnlyList<string>? RequiredGroups = null,
    int? ExactCount = null, IReadOnlyList<string>? CompositeOf = null,
    int? SourceTemplateCount = null, string? SourceMap = null);

public sealed record CompositeTemplate(string SourceId, IReadOnlyList<string> UnitIds, int ExpectedCount);
public sealed record CompositeSourceMap(IReadOnlyList<CompositeTemplate> Templates);

public sealed record UnitManifest(IReadOnlyList<RequiredUnit> Units);

public sealed record CoverageReport(
    string Runner, bool Complete, int RequiredCount, int PassedCount,
    IReadOnlyList<UnitResult> Units, IReadOnlyList<string> Errors);

public static class Coverage
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        WriteIndented = true,
        RespectRequiredConstructorParameters = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter() }
    };

    public static IReadOnlyList<RequiredUnit> Load(string directory)
    {
        var units = new List<RequiredUnit>();
        if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
        foreach (var name in new[] { "host.json", "ui.json", "ownership.json" })
        {
            var path = Path.Combine(directory, name);
            if (!File.Exists(path))
            {
                units.Add(new RequiredUnit($"missing-manifest.{name}", "Host", 1));
                continue;
            }
            var manifest = JsonSerializer.Deserialize<UnitManifest>(File.ReadAllText(path), JsonOptions)
                ?? throw new InvalidDataException($"Null required manifest: {path}");
            units.AddRange(manifest.Units);
        }
        return units;
    }

    public static CoverageReport Evaluate(
        IReadOnlyList<RequiredUnit> required,
        IReadOnlyList<IValidationSuite> suites,
        IReadOnlyList<UnitResult> results,
        IReadOnlyList<string>? executionErrors = null,
        string? sourceDirectory = null)
    {
        var errors = new List<string>(executionErrors ?? []);
        var ledger = new List<UnitResult>();
        var (requirements, executors, definitionErrors) = Definitions(required, suites);
        errors.AddRange(definitionErrors);
        var observed = new Dictionary<string, List<UnitResult>>(StringComparer.Ordinal);
        foreach (var result in results)
        {
            if (!requirements.ContainsKey(result.Id)) errors.Add($"Undeclared result unit: {result.Id}");
            if (requirements.TryGetValue(result.Id, out var declaration) && declaration.CompositeOf is not null)
                errors.Add($"Composite evidence must be derived by the host, not submitted: {result.Id}");
            if (!observed.TryGetValue(result.Id, out var rows))
            {
                rows = [];
                observed.Add(result.Id, rows);
            }
            rows.Add(result);
        }
        foreach (var (id, unit) in requirements.Where(pair => pair.Value.CompositeOf is null))
        {
            var count = executors.GetValueOrDefault(id);
            if (count != 1)
            {
                var detail = count == 0 ? "Executor is not implemented" : $"Duplicate executors: {count}";
                errors.Add($"{id}: {detail}");
                ledger.Add(new UnitResult(id, UnitStatus.Incomplete, 0, detail));
                continue;
            }
            if (!observed.TryGetValue(id, out var rows) || rows.Count != 1)
            {
                var detail = rows is null ? "Mandatory unit did not run" : $"Duplicate results: {rows.Count}";
                errors.Add($"{id}: {detail}");
                ledger.Add(new UnitResult(id, UnitStatus.Incomplete, 0, detail));
                continue;
            }
            ledger.Add(ValidateResult(unit, rows[0], errors));
        }
        foreach (var unit in requirements.Values.Where(unit => unit.CompositeOf is not null))
        {
            try
            {
                if (executors.GetValueOrDefault(unit.Id) != 1 || observed.ContainsKey(unit.Id))
                    throw new InvalidDataException("A composite has a duplicate or directly submitted executor/result");
                var composite = DeriveComposite(unit, ledger, sourceDirectory);
                ledger.Add(ValidateResult(unit, composite, errors));
            }
            catch (Exception error) when (error is InvalidDataException or IOException or JsonException or ArgumentException or OverflowException)
            {
                errors.Add($"{unit.Id}: {error.Message}");
                ledger.Add(new UnitResult(unit.Id, UnitStatus.Incomplete, 0, "Composite proof is incomplete; see coverage errors"));
            }
        }
        var passed = ledger.Count(result => result.Status == UnitStatus.Passed);
        return new CoverageReport("CompiledValidationRunner", errors.Count == 0 && passed > 0 &&
            passed == required.Count, required.Count, passed, ledger, errors);
    }

    public static IReadOnlyList<string> RegistryErrors(IReadOnlyList<RequiredUnit> required, IReadOnlyList<IValidationSuite> suites) =>
        Definitions(required, suites).Errors;

    private static (Dictionary<string, RequiredUnit> Requirements, Dictionary<string, int> Executors, List<string> Errors)
        Definitions(IReadOnlyList<RequiredUnit> required, IReadOnlyList<IValidationSuite> suites)
    {
        var errors = new List<string>();
        var requirements = new Dictionary<string, RequiredUnit>(StringComparer.Ordinal);
        if (required.Count == 0) errors.Add("Required-unit manifest is empty");
        foreach (var unit in required)
        {
            if (unit is null || unit.Id is null)
            {
                errors.Add("Required-unit manifest contains a null unit or ID");
                continue;
            }
            if (!ConsoleReport.ValidId(unit.Id) || string.IsNullOrWhiteSpace(unit.Owner) ||
                unit.MinimumCount <= 0 || (unit.ExactCount is not null && unit.ExactCount < unit.MinimumCount))
                errors.Add($"Invalid required unit: {unit.Id}");
            if (!requirements.TryAdd(unit.Id, unit)) errors.Add($"Duplicate required unit: {unit.Id}");
            if (unit.RequiredGroups is not null &&
                (unit.RequiredGroups.Any(string.IsNullOrWhiteSpace) ||
                 unit.RequiredGroups.Distinct(StringComparer.Ordinal).Count() != unit.RequiredGroups.Count))
                errors.Add($"Invalid required groups: {unit.Id}");
            if (unit.CompositeOf is not null &&
                (unit.CompositeOf.Count == 0 || unit.CompositeOf.Distinct(StringComparer.Ordinal).Count() != unit.CompositeOf.Count ||
                 unit.CompositeOf.Contains(unit.Id, StringComparer.Ordinal) || unit.SourceTemplateCount is null or <= 0 ||
                 string.IsNullOrWhiteSpace(unit.SourceMap)))
                errors.Add($"Invalid composite declaration: {unit.Id}");
        }
        var executors = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var unit in requirements.Values.Where(unit => unit.CompositeOf is not null))
        {
            executors[unit.Id] = 1;
            foreach (var id in unit.CompositeOf!)
                if (!requirements.TryGetValue(id, out var dependency) || dependency.CompositeOf is not null)
                    errors.Add($"Composite dependency is unknown or nested: {id}");
        }
        var suiteNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var suite in suites)
        {
            if (string.IsNullOrWhiteSpace(suite.Id) || !suiteNames.Add(suite.Id))
                errors.Add($"Invalid or duplicate suite ID: {suite.Id}");
            if (suite.UnitIds.Count == 0) errors.Add($"Suite has no units: {suite.Id}");
            foreach (var id in suite.UnitIds)
            {
                if (!ConsoleReport.ValidId(id))
                {
                    errors.Add($"Invalid executor unit ID in suite: {suite.Id}");
                    continue;
                }
                if (!requirements.ContainsKey(id)) errors.Add($"Undeclared executor unit: {id}");
                executors[id] = executors.GetValueOrDefault(id) + 1;
            }
        }
        return (requirements, executors, errors);
    }

    private static UnitResult ValidateResult(RequiredUnit unit, UnitResult result, List<string> errors)
    {
            var problems = new List<string>();
            if (result.Status != UnitStatus.Passed) problems.Add($"Status is {result.Status}");
            if (result.ExecutedCount < unit.MinimumCount) problems.Add($"Executed {result.ExecutedCount}; minimum {unit.MinimumCount}");
            if (unit.ExactCount is not null && result.ExecutedCount != unit.ExactCount)
                problems.Add($"Executed {result.ExecutedCount}; expected exactly {unit.ExactCount}");
            if (string.IsNullOrWhiteSpace(result.Evidence)) problems.Add("No execution evidence");
            foreach (var group in unit.RequiredGroups ?? [])
                if ((result.Groups ?? []).Count(value => string.Equals(value, group, StringComparison.Ordinal)) != 1)
                    problems.Add($"Required group did not pass exactly once: {group}");
            if (problems.Count != 0)
            {
                errors.Add($"{unit.Id}: {string.Join("; ", problems)}");
                return result with
                {
                    Status = result.Status is UnitStatus.Incomplete or UnitStatus.Skipped ? result.Status : UnitStatus.Failed,
                    Evidence = $"{result.Evidence}; {string.Join("; ", problems)}"
                };
            }
            return result;
    }

    private static UnitResult DeriveComposite(RequiredUnit unit, IReadOnlyList<UnitResult> ledger, string? sourceDirectory)
    {
        if (unit.CompositeOf is null || sourceDirectory is null || unit.SourceMap is null || Path.IsPathRooted(unit.SourceMap))
            throw new InvalidDataException("Composite declaration/source directory is missing or invalid");
        var directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(sourceDirectory));
        var path = Path.GetFullPath(Path.Combine(directory, unit.SourceMap));
        if (!path.StartsWith(directory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Composite source map escapes the current source directory");
        var map = JsonSerializer.Deserialize<CompositeSourceMap>(File.ReadAllText(path), JsonOptions)
            ?? throw new InvalidDataException("Composite source map is null");
        if (map.Templates is null || map.Templates.Count != unit.SourceTemplateCount ||
            map.Templates.Any(template => template is null || string.IsNullOrWhiteSpace(template.SourceId) || template.UnitIds is null ||
                template.UnitIds.Count == 0 || template.ExpectedCount <= 0) ||
            map.Templates.Select(template => template.SourceId).Distinct(StringComparer.Ordinal).Count() != map.Templates.Count)
            throw new InvalidDataException("Composite source templates are missing, duplicate, or malformed");
        var mapped = map.Templates.SelectMany(template => template.UnitIds).ToArray();
        if (mapped.Distinct(StringComparer.Ordinal).Count() != mapped.Length ||
            mapped.Length != unit.CompositeOf.Count ||
            !mapped.ToHashSet(StringComparer.Ordinal).SetEquals(unit.CompositeOf))
            throw new InvalidDataException("Composite dependencies do not correspond exactly once to every source template");
        var dependencies = new Dictionary<string, UnitResult>(StringComparer.Ordinal);
        foreach (var id in unit.CompositeOf)
        {
            var matches = ledger.Where(result => result.Id == id).ToArray();
            if (matches.Length != 1 || matches[0].Status != UnitStatus.Passed || matches[0].ExecutedCount <= 0)
                throw new InvalidDataException("A mandatory composite dependency did not pass exactly once");
            dependencies.Add(id, matches[0]);
        }
        foreach (var template in map.Templates)
            if (template.UnitIds.Sum(id => dependencies[id].ExecutedCount) != template.ExpectedCount)
                throw new InvalidDataException("A source template did not execute its exact original expanded case count");
        var groups = dependencies.Values.SelectMany(result => result.Groups ?? []).Distinct(StringComparer.Ordinal).ToArray();
        return new UnitResult(unit.Id, UnitStatus.Passed, dependencies.Values.Sum(result => result.ExecutedCount),
            $"Derived from {map.Templates.Count} independently mapped original source templates and actual dependency receipts", groups);
    }

    public static void ValidateProvenance(IValidationSuite suite, IReadOnlyList<UnitResult> results)
    {
        if (results.Any(result => !suite.UnitIds.Contains(result.Id, StringComparer.Ordinal)))
            throw new InvalidDataException("A suite returned evidence for a unit it does not own");
    }
}
