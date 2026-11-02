using System.Text.Json;
using System.IO;
using System.Text.RegularExpressions;

namespace GraphCode.Validation.Adapters;

public static class EvidenceParser
{
    public static UnitResult Structured(
        string unitId, string suite, string output, int minimumCount, int? exactCount = null,
        bool requireSkipped = true)
    {
        var matches = new List<JsonElement>();
        foreach (var line in Lines(output))
        {
            if (!line.StartsWith("{", StringComparison.Ordinal)) continue;
            using var document = JsonDocument.Parse(line);
            if (document.RootElement.TryGetProperty("suite", out var name) &&
                name.ValueKind == JsonValueKind.String && name.GetString() == suite)
                matches.Add(document.RootElement.Clone());
        }
        if (matches.Count != 1) throw new InvalidDataException($"{suite}: expected one structured summary; observed {matches.Count}");
        var summary = matches[0];
        var executed = Integer(summary, "executed");
        if (executed < minimumCount || (exactCount.HasValue && executed != exactCount.Value) ||
            Integer(summary, "passed") != executed || Integer(summary, "failed") != 0 ||
            (requireSkipped && Integer(summary, "skipped") != 0) ||
            (summary.TryGetProperty("notRun", out _) && Integer(summary, "notRun") != 0))
            throw new InvalidDataException($"{suite}: incomplete or failed suite summary");
        return new UnitResult(unitId, UnitStatus.Passed, executed, $"{suite}: executed={executed}; passed={executed}; failed=0; skipped=0");
    }

    public static UnitResult PesterVersion(string output)
    {
        const string marker = "PesterVersion.Tests.ps1: PASS; executed=14";
        var lines = Lines(output);
        var cases = lines.Where(line => line.StartsWith("PASS: ", StringComparison.Ordinal)).ToArray();
        if (lines.Count(line => line == marker) != 1 || cases.Length != 14 ||
            cases.Distinct(StringComparer.Ordinal).Count() != 14)
            throw new InvalidDataException("PesterVersion: expected 14 distinct executed cases and exactly one summary");
        return new UnitResult("ps.pester-version", UnitStatus.Passed, cases.Length, marker);
    }

    public static UnitResult IsolatedEnvironment(string output)
    {
        var summaries = Lines(output).Where(line =>
            Regex.IsMatch(line, "^Isolated process environment contracts: [0-9]+ cases; phase=REGRESSION$",
                RegexOptions.CultureInvariant)).ToArray();
        if (summaries.Length != 1) throw new InvalidDataException("Isolated environment: missing or duplicate regression count");
        var match = Regex.Match(summaries[0], "contracts: ([0-9]+) cases", RegexOptions.CultureInvariant);
        var count = int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        if (count != 14) throw new InvalidDataException($"Isolated environment: expected all 14 cases; observed {count}");
        return new UnitResult("ps.isolated-process-environment", UnitStatus.Passed, count, summaries[0]);
    }

    public static UnitResult AgentCommand(string output)
    {
        const string marker = "Invoke-AgentCommand.Tests.ps1: PASS; executed=6; cases=argument-stream-marker,zero-arguments,existing-console,existing-marker,parse-failure,child-nonzero";
        var lines = Lines(output);
        if (lines.Count != 1 || lines[0] != marker)
            throw new InvalidDataException("Agent command: expected the exact six-case production suite summary");
        return new UnitResult("ps.agent-command", UnitStatus.Passed, 6, marker);
    }

    public static IReadOnlyList<string> CaptureGroups(string reportPath, IReadOnlyList<string> required)
    {
        using var report = JsonDocument.Parse(File.ReadAllText(reportPath));
        var cases = report.RootElement.GetProperty("cases").EnumerateArray().ToArray();
        foreach (var name in required)
        {
            var matches = cases.Where(row => row.GetProperty("name").GetString() == name).ToArray();
            if (matches.Length != 1 || matches[0].GetProperty("passed").ValueKind != JsonValueKind.True)
                throw new InvalidDataException($"Capture group did not pass exactly once: {name}");
        }
        return required.ToArray();
    }

    private static int Integer(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt32(out var count))
            throw new InvalidDataException($"Suite summary requires integer {property}");
        return count;
    }

    private static IReadOnlyList<string> Lines(string text) =>
        text.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries);
}
