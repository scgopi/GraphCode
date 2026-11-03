using System.IO;
using System.Text.Json;

namespace GraphCode.Validation.Host;

public static class HostFixture
{
    public static int? TryRun(string[] args)
    {
        if (args.Length == 0 || args[0] != "--host-fixture") return null;
        if (args.Length != 4 || args[1] != "provider-compiler" || args[2] != "build" ||
            args[3] is not ("-Demit-win32-host=true" or "-Dtarget=x86_64-windows-gnu"))
            throw new ArgumentException("Unknown controlled host fixture invocation");
        var log = Environment.GetEnvironmentVariable("GRAPHCODE_PROVIDER_COMPILER_LOG")
            ?? throw new InvalidOperationException("Controlled provider compiler log is required");
        File.AppendAllText(log, JsonSerializer.Serialize(args[2..]) + "\n");
        var behavior = Environment.GetEnvironmentVariable("GRAPHCODE_PROVIDER_COMPILER_BEHAVIOR");
        if (behavior == "fail") return 7;
        if (behavior == "missing") return 0;
        if (!string.IsNullOrEmpty(behavior)) throw new ArgumentException("Unknown controlled compiler behavior");
        var artifact = args[3] == "-Demit-win32-host=true"
            ? Path.Combine("zig-out", "lib", "winghostty-win32-host.lib")
            : Path.Combine("zig-out", "bin", "zmx.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(artifact)!);
        File.WriteAllBytes(artifact, []);
        return 0;
    }
}
