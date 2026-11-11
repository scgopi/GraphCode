using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public static class OwnedFixture
{
    public static ProcessStartInfo Command(string mode, string root, params string[] arguments)
    {
        string host = Environment.ProcessPath ?? throw new InvalidOperationException("Current process executable unavailable.");
        var start = new ProcessStartInfo(host)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = root,
            StandardOutputEncoding = OwnedByteStreamCapture.RequireUtf8NoBom(new UTF8Encoding(false, true)),
            StandardErrorEncoding = OwnedByteStreamCapture.RequireUtf8NoBom(new UTF8Encoding(false, true))
        };
        if (Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(Assembly.GetEntryAssembly()!.Location);
        foreach (string value in new[] { "--ownership-fixture", mode, root }) start.ArgumentList.Add(value);
        foreach (string argument in arguments) start.ArgumentList.Add(argument);
        start.Environment["TEMP"] = root;
        start.Environment["TMP"] = root;
        return start;
    }

    public static async Task<int?> TryRunAsync(string[] args)
    {
        if (args.Length == 0 || args[0] != "--ownership-fixture") return null;
        Console.OutputEncoding = new UTF8Encoding(false);
        if (args.Length < 3) throw new ArgumentException("Owned fixture requires a mode and existing owned root.");
        string mode = args[1], root = Path.GetFullPath(args[2]);
        if (!Directory.Exists(root)) throw new DirectoryNotFoundException(root);
        if (await ShellScopeNativeFixture.TryRunAsync(mode, root).ConfigureAwait(false) is int scopeExit)
            return scopeExit;
        if (mode.StartsWith("bytes-", StringComparison.Ordinal))
        {
            byte[] bytes = BytesForMode(mode);
            using Stream output = Console.OpenStandardOutput();
            await output.WriteAsync(bytes).ConfigureAwait(false);
            await output.FlushAsync().ConfigureAwait(false);
            return 0;
        }
        if (mode == "protocol")
        {
            if (args.Length != 6) throw new ArgumentException("Protocol fixture requires pipe name and both owner paths.");
            await ServeProtocolAsync(root, args[3], args[4], args[5]).ConfigureAwait(false);
            return 0;
        }

        if (mode == "descendant")
        {
            File.WriteAllText(Path.Combine(root, "descendant-ready"), "ready");
            await Task.Delay(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
            return 0;
        }
        if (mode == "echo")
        {
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                arguments = args[3..], present = Environment.GetEnvironmentVariables().Contains("OWNERSHIP_EMPTY"),
                value = Environment.GetEnvironmentVariable("OWNERSHIP_EMPTY"),
                absent = !Environment.GetEnvironmentVariables().Contains("OWNERSHIP_ABSENT"),
                cwd = Environment.CurrentDirectory
            }));
            return 0;
        }
        if (mode is not ("normal" or "abrupt" or "timeout" or "inherited" or "inherited-timeout"))
            throw new ArgumentException("Unknown owned fixture mode: " + mode);
        Console.Out.WriteLine("owned-capture-stdout \uD83D\uDE80");
        Console.Error.WriteLine("owned-capture-stderr \u03BB");
        if (mode is "inherited" or "inherited-timeout")
        {
            using Process child = Process.Start(CommandForInheritedChild(root))
                ?? throw new InvalidOperationException("Controlled descendant did not start.");
            File.WriteAllText(Path.Combine(root, "descendant.json"),
                JsonSerializer.Serialize(new { pid = child.Id, startUtcTicks = child.StartTime.ToUniversalTime().Ticks }));
            var readyLimit = new Deadline(TimeSpan.FromSeconds(5));
            while (!File.Exists(Path.Combine(root, "descendant-ready")))
            {
                if (readyLimit.Expired) throw new TimeoutException("Controlled descendant not ready.");
                await Task.Delay(10).ConfigureAwait(false);
            }
        }
        File.WriteAllText(Path.Combine(root, "ready"), "ready");
        if (mode is "timeout" or "inherited-timeout") await Task.Delay(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
        return mode == "abrupt" ? 23 : 0;
    }

    public static byte[] BytesForMode(string mode)
    {
        const string json = "{\"value\":\"owned\"}";
        return mode switch
        {
            "bytes-utf8-bom" => [0xef, 0xbb, 0xbf, .. Encoding.UTF8.GetBytes(json)],
            "bytes-utf16-bom" => [0xff, 0xfe, .. Encoding.Unicode.GetBytes(json)],
            "bytes-invalid-utf8" => [0x7b, 0xc3, 0x28, 0x7d],
            "bytes-utf8-supplementary" => Encoding.UTF8.GetBytes(new string('a', 4095) + "\uD83D\uDE80tail"),
            _ => throw new ArgumentException("Unknown byte fixture mode.", nameof(mode))
        };
    }

    private static ProcessStartInfo CommandForInheritedChild(string root)
    {
        ProcessStartInfo start = Command("descendant", root);
        start.RedirectStandardOutput = false;
        start.RedirectStandardError = false;
        start.StandardOutputEncoding = null;
        start.StandardErrorEncoding = null;
        return start;
    }

    private static async Task ServeProtocolAsync(string root, string pipeName, string alpha, string beta)
    {
        var peer = new MultiProjectPeer(alpha, beta);
        await using var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var deadline = new Deadline(TimeSpan.FromSeconds(10));
        using var connect = new CancellationTokenSource(deadline.Remaining);
        await server.WaitForConnectionAsync(connect.Token).ConfigureAwait(false);
        using (JsonDocument? hello = await PipeFrames.ReadAsync(server, deadline).ConfigureAwait(false))
        {
            JsonObject frame = MultiProjectJson.Object(hello?.RootElement.GetRawText() ?? throw new EndOfStreamException());
            MultiProjectJson.Shape(frame, "hello", "version", "kind", "supportedVersions");
            if (MultiProjectJson.Integer(frame["version"], "version") != 2 || MultiProjectJson.String(frame["kind"], "kind") != "hello" ||
                frame["supportedVersions"]?.ToJsonString() != "[1,2]")
                throw new InvalidDataException("Owned protocol hello differs.");
        }
        await PipeFrames.WriteAsync(server, "{\"version\":2,\"kind\":\"hello\",\"selectedVersion\":2}", deadline, 7).ConfigureAwait(false);
        while (true)
        {
            using JsonDocument? document = await PipeFrames.ReadAsync(server, deadline).ConfigureAwait(false);
            if (document == null) break;
            JsonObject frame = MultiProjectJson.Object(document.RootElement.GetRawText());
            if (frame.ContainsKey("token"))
            {
                JsonObject publication = peer.Control(frame);
                await PipeFrames.WriteAsync(server, publication.ToJsonString(), deadline, 7).ConfigureAwait(false);
                peer.CompletePublication(publication, "control", frame["token"]!.GetValue<string>());
                continue;
            }
            MultiProjectReply reply = peer.Request(frame);
            if (reply.Response != null)
            {
                await PipeFrames.WriteAsync(server, reply.Response.ToJsonString(), deadline, 7).ConfigureAwait(false);
                peer.CompleteResponse(reply.Response);
            }
            string id = frame["requestID"]!.GetValue<string>();
            string[] owners = frame["command"]!["listRecentProjects"] != null ? [alpha, beta] :
                reply.PublishPath != null ? [reply.PublishPath] : [];
            foreach (string path in owners)
            {
                JsonObject publication = peer.Publication(path);
                await PipeFrames.WriteAsync(server, publication.ToJsonString(), deadline, 7).ConfigureAwait(false);
                peer.CompletePublication(publication, reply.PublishPath == null ? "initial" : "rename", id);
            }
        }
        using var receipt = new FileStream(Path.Combine(root, "peer.json"), FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        await JsonSerializer.SerializeAsync(receipt, peer.Snapshot()).ConfigureAwait(false);
        receipt.Flush(true);
    }
}
