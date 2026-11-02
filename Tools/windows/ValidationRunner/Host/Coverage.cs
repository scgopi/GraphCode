using System.Text.Json;
using System.Text.Json.Serialization;

namespace GraphCode.Validation.Host;

public sealed record RequiredUnit(
    string Id, string Owner, int MinimumCount, IReadOnlyList<string>? RequiredGroups = null,
    int? ExactCount = null);

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
        IReadOnlyList<string>? executionErrors = null)
    {
        var errors = new List<string>(executionErrors ?? []);
        var ledger = new List<UnitResult>();
        var requirements = new Dictionary<string, RequiredUnit>(StringComparer.Ordinal);
        if (required.Count == 0) errors.Add("Required-unit manifest is empty");
        foreach (var unit in required)
        {
            if (string.IsNullOrWhiteSpace(unit.Id) || string.IsNullOrWhiteSpace(unit.Owner) ||
                unit.MinimumCount <= 0 || (unit.ExactCount is not null && unit.ExactCount < unit.MinimumCount))
                errors.Add($"Invalid required unit: {unit.Id}");
            if (!requirements.TryAdd(unit.Id, unit)) errors.Add($"Duplicate required unit: {unit.Id}");
            if (unit.RequiredGroups is not null &&
                (unit.RequiredGroups.Any(string.IsNullOrWhiteSpace) ||
                 unit.RequiredGroups.Distinct(StringComparer.Ordinal).Count() != unit.RequiredGroups.Count))
                errors.Add($"Invalid required groups: {unit.Id}");
        }
        var executors = new Dictionary<string, int>(StringComparer.Ordinal);
        var suiteNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var suite in suites)
        {
            if (string.IsNullOrWhiteSpace(suite.Id) || !suiteNames.Add(suite.Id))
                errors.Add($"Invalid or duplicate suite ID: {suite.Id}");
            if (suite.UnitIds.Count == 0) errors.Add($"Suite has no units: {suite.Id}");
            foreach (var id in suite.UnitIds)
            {
                if (!requirements.ContainsKey(id)) errors.Add($"Undeclared executor unit: {id}");
                executors[id] = executors.GetValueOrDefault(id) + 1;
            }
        }
        var observed = new Dictionary<string, List<UnitResult>>(StringComparer.Ordinal);
        foreach (var result in results)
        {
            if (!requirements.ContainsKey(result.Id)) errors.Add($"Undeclared result unit: {result.Id}");
            if (!observed.TryGetValue(result.Id, out var rows))
            {
                rows = [];
                observed.Add(result.Id, rows);
            }
            rows.Add(result);
        }
        foreach (var (id, unit) in requirements)
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
            var result = rows[0];
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
                errors.Add($"{id}: {string.Join("; ", problems)}");
                ledger.Add(result with { Status = UnitStatus.Failed, Evidence = $"{result.Evidence}; {string.Join("; ", problems)}" });
            }
            else ledger.Add(result);
        }
        var passed = ledger.Count(result => result.Status == UnitStatus.Passed);
        return new CoverageReport("CompiledValidationRunner", errors.Count == 0 && passed > 0 &&
            passed == required.Count, required.Count, passed, ledger, errors);
    }
}
