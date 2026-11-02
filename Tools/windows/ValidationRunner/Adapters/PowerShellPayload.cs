using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using GraphCode.Validation.Ownership;

namespace GraphCode.Validation.Adapters;

public static class PowerShellPayload
{
    public static async Task<string> RunAsync(
        ValidationContext context, string id, string relativeScript, IReadOnlyList<string> arguments,
        CancellationToken cancellationToken)
    {
        var executable = Environment.GetEnvironmentVariable("GRAPHCODE_VALIDATION_PWSH") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable))
            throw new FileNotFoundException("Set GRAPHCODE_VALIDATION_PWSH to the supported PowerShell executable", executable);
        var script = Path.GetFullPath(Path.Combine(context.RepositoryRoot, relativeScript));
        if (!script.StartsWith(Path.TrimEndingDirectorySeparator(context.RepositoryRoot) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase) || !File.Exists(script))
            throw new FileNotFoundException("Validation payload must exist in the current repository", script);
        if (Path.GetFileName(script).Equals("ValidationRunner.Tests.ps1", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The legacy monolithic runner is not an allowed payload");
        var artifacts = Path.Combine(context.ArtifactRoot, id + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(artifacts);
        var tempParent = Path.Combine(Path.GetPathRoot(context.RepositoryRoot) ??
            throw new InvalidDataException("Repository has no volume root"), "gc-validation");
        Directory.CreateDirectory(tempParent);
        var temp = Path.Combine(tempParent, Guid.NewGuid().ToString("N"));
        GraphCode.ValidationFixtureDirectoryNative.Create(temp);
        await File.WriteAllTextAsync(Path.Combine(artifacts, "scratch-root.txt"), temp, cancellationToken);
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = context.RepositoryRoot,
            StandardOutputEncoding = new UTF8Encoding(false, true),
            StandardErrorEncoding = new UTF8Encoding(false, true)
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script }.Concat(arguments))
            start.ArgumentList.Add(argument);
        start.Environment["TEMP"] = temp;
        start.Environment["TMP"] = temp;
        start.Environment["GRAPHCODE_VALIDATION_ASSEMBLY"] = Assembly.GetExecutingAssembly().Location;
        var result = await OwnedChildSupervisor.RunAsync(start, TimeSpan.FromMinutes(12), artifacts, cancellationToken);
        if (!result.Cleanup.CanRelease || !result.Cleanup.ResourcesClosed)
            throw new InvalidOperationException($"{id}: owned child cleanup is UNKNOWN; artifacts retained: {artifacts}");
        if (result.StandardOutput.Contains("GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven", StringComparison.Ordinal))
        {
            var failure = new InvalidOperationException($"{id}: descendant reported UNKNOWN ownership; artifacts retained: {artifacts}");
            failure.Data["GraphCodeValidationRootRetentionRequired"] = true;
            throw failure;
        }
        if (result.ExitCode != 0 || !string.IsNullOrWhiteSpace(result.StandardError))
            throw new InvalidOperationException($"{id}: protected payload failed (exit={result.ExitCode}); " +
                $"stdout/stderr and scratch receipt retained: {artifacts}");
        return result.StandardOutput;
    }
}
