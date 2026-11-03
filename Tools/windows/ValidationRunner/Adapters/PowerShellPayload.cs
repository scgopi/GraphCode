using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Security.Cryptography;
using GraphCode.Validation.Ownership;
using GraphCode.Validation.Host;

namespace GraphCode.Validation.Adapters;

public static class PowerShellPayload
{
    public sealed record Receipt(string Output, string ArtifactRoot, string StdoutTextSha256);

    public static string CreateScratchRoot(string repositoryRoot)
    {
        var parent = Path.Combine(Path.GetPathRoot(repositoryRoot) ??
            throw new InvalidDataException("Repository has no volume root"), "gc-v");
        Directory.CreateDirectory(parent);
        var path = Path.Combine(parent, Guid.NewGuid().ToString("N")[..16]);
        GraphCode.ValidationFixtureDirectoryNative.Create(path);
        return path;
    }

    public static async Task<Receipt> RunAsync(
        ValidationContext context, string id, string relativeScript, IReadOnlyList<string> arguments,
        CancellationToken cancellationToken, Func<string, bool>? expectedDiagnostics = null)
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
        var temp = CreateScratchRoot(context.RepositoryRoot);
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
        var unknown = false;
        var observer = new RetentionSignalObserver(() => unknown = true);
        observer.OnText(result.StandardOutput);
        observer.OnEof();
        if (unknown)
        {
            TerminalSafety.MarkUnknown();
            var failure = new InvalidOperationException($"{id}: descendant reported UNKNOWN ownership; artifacts retained: {artifacts}");
            failure.Data["GraphCodeValidationRootRetentionRequired"] = true;
            throw failure;
        }
        if (result.ExitCode != 0 || (!string.IsNullOrWhiteSpace(result.StandardError) &&
            (expectedDiagnostics is null || !expectedDiagnostics(result.StandardError))))
            throw new InvalidOperationException($"{id}: protected payload failed (exit={result.ExitCode}); " +
                $"stdout/stderr and scratch receipt retained: {artifacts}");
        return new Receipt(result.StandardOutput, artifacts,
            Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(result.StandardOutput))));
    }
}
