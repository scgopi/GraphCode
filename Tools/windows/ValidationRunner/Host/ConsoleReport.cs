using System.Text.RegularExpressions;

namespace GraphCode.Validation.Host;

public static class ConsoleReport
{
    public static bool ValidId(string id) =>
        Regex.IsMatch(id, "^[a-z0-9][a-z0-9.-]{0,160}$", RegexOptions.CultureInvariant);

    public static string Unit(UnitResult result) =>
        $"{result.Status}: {(ValidId(result.Id) ? result.Id : "[invalid-id]")} executed={result.ExecutedCount}";

    public static string Error(int index) => $"ERROR {index}: details retained in coverage.json";
}
