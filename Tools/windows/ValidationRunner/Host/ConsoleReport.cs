using System.Text.RegularExpressions;

namespace GraphCode.Validation.Host;

public static class ConsoleReport
{
    public static bool ValidId(string? id) =>
        id is not null && Regex.IsMatch(id, "^[a-z0-9][a-z0-9.-]{0,160}\\z", RegexOptions.CultureInvariant);

    public static string Unit(UnitResult result) =>
        $"{result.Status}: {(ValidId(result.Id) ? result.Id : "[invalid-id]")} executed={result.ExecutedCount}";

    public static string Error(int index) => $"ERROR {index}: details retained in coverage.json";

    public static string SuiteFailure(string suiteId, string exceptionType) =>
        $"SUITE_FAILURE id={(ValidId(suiteId) ? suiteId : "[invalid-id]")} " +
        $"exception={(Regex.IsMatch(exceptionType, "^[A-Za-z_][A-Za-z0-9_.+`]{0,255}\\z", RegexOptions.CultureInvariant) ? exceptionType : "[invalid-type]")}; details retained in coverage.json";
}
