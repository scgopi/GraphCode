using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace GraphCode.Validation.Ownership;

public static class SuiteRegistration
{
    public static IReadOnlyList<IValidationSuite> CreateSuites() => [new OwnershipSuite()];
}

public sealed class OwnershipSuite : IValidationSuite
{
    private const string ListId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
    private const string RenameId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    private const string Token = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
    private static readonly string[] managedIds =
    [
        "quote-empty", "quote-trailing-slash", "quote-embedded", "quote-unicode", "quote-nul",
        "stream-raw", "stream-surrogate-boundary", "stream-no-overwrite", "stream-independent-faults", "stream-shared-deadline",
        "receipt-valid", "receipt-existing", "receipt-missing", "receipt-file", "receipt-absent",
        "receipt-duplicate-json", "receipt-foreign-root", "receipt-over-limit",
        "proof-success", "proof-root-survivor", "proof-job-survivor", "proof-stdout-fault", "proof-stderr-fault",
        "cleanup-success", "cleanup-root-survivor", "cleanup-job-survivor", "cleanup-stdout-fault",
        "cleanup-both-stream-faults", "cleanup-primary-error", "cleanup-only-error", "cleanup-original-deadline", "cleanup-later-actions",
        "json-malformed", "json-duplicate", "json-nested-duplicate", "json-array", "json-case-sensitive",
        "frame-fragmented-unicode", "frame-clean-eof", "frame-short-header", "frame-short-body", "frame-zero", "frame-over-limit", "frame-invalid-utf8",
        "peer-positive-rename", "peer-resume-unchanged", "peer-foreign-owner", "peer-foreign-node",
        "peer-missing-title", "peer-extra-field", "peer-title-type", "peer-version-string", "peer-version-bool",
        "peer-request-id", "peer-blank-title", "peer-request-duplicate", "peer-unanswered-publication",
        "peer-response-unknown", "peer-response-extra", "peer-response-type", "peer-response-duplicate",
        "peer-control-positive", "peer-control-owner", "peer-control-selection", "peer-control-extra", "peer-control-type",
        "peer-control-duplicate", "peer-control-second"
    ];
    private static readonly string[] nativeIds = ["normal", "abrupt", "timeout", "inherited", "inherited-timeout", "arguments-environment", "real-pipe"];
    private static readonly (string Id, string Evidence)[] unported =
    [
        ("legacy.ownership-receipts", "Actual PS producer/stream/scope assertions: Test-UiaOwnershipReceiptContracts, source 90-168; exactly seven cases."),
        ("legacy.retention-boundary", "Actual PS producer/Invoke-Native/isolation boundary: Test-UiaRetentionBoundaryContracts, source 292-429; exactly six cases including receipt-only and sentinel-only exit0/17 obligations."),
        ("legacy.capture-ownership", "Actual ScriptMethod/mock/ErrorRecord assertions: Test-UiaCaptureOwnershipContracts, source 430-596; exactly fourteen cases; native helper linkage requires host adapters."),
        ("legacy.tree-ownership", "Actual PS lease registry and continuation assertions: Test-UiaTreeOwnershipContracts, source 597-673; exactly four cases."),
        ("legacy.provider-ownership", "Actual PS advisory-CIM refusal/removed hiding assertions: Test-UiaProviderOwnershipContracts, source 674-757; exactly four cases."),
        ("legacy.pre-uia-isolation", "Actual runner PS region and environment/scope assertions: Test-PreUiaProcessIsolationContracts, source 892-988; exactly ten cases."),
        ("legacy.mixed-multiproject", "Complete mixed source 1672-4245 remains mandatory: UI predicates, native/fresh snapshot policies, receipts, strict protocol, owned real pipes, eight bounded-capture and primary/cleanup negative controls. Source invocation inventories are not executed counts."),
        ("legacy.peer-emission", "Assert-MultiProjectPeerEmissionContract source 4247-4265 requires actual PS AST source correspondence."),
        ("legacy.rename-submit", "Assert-MultiProjectRenameSubmitContract source 4266-4289 requires actual caller/production Zig route correspondence."),
        ("legacy.fresh-capture", "Assert-MultiProjectFreshCaptureContract source 4290-4315 requires actual ownership/cache/observer correspondence."),
        ("legacy.packaging-shared-linkage", "Packaging.Standalone.Tests.ps1 must load this complete StandaloneProcessJob implementation, not its embedded duplicate."),
        ("legacy.uia-shared-linkage", "uia-live-gate.ps1 must load these complete UiaOwnedStreamCapture/StandaloneProcessJob implementations, including actual native membership.")
    ];

    public string Id => "ownership";
    public IReadOnlyList<string> UnitIds { get; } = managedIds.Select(id => "ownership.managed." + id)
        .Concat(nativeIds.Select(id => "ownership.native." + id)).Concat(unported.Select(p => "ownership." + p.Id)).ToArray();

    public async Task<IReadOnlyList<UnitResult>> RunAsync(ValidationContext context, CancellationToken cancellationToken)
    {
        string root = Path.Combine(context.ArtifactRoot, "ownership-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string alpha = Path.Combine(root, "Alpha"), beta = Path.Combine(root, "Beta");
        Directory.CreateDirectory(alpha);
        Directory.CreateDirectory(beta);
        var results = new List<UnitResult>();
        foreach (string id in managedIds)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await ExecuteAsync("ownership.managed." + id, () => ManagedAsync(id, root, alpha, beta), results, "managed").ConfigureAwait(false);
        }
        foreach (string id in nativeIds)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await ExecuteAsync("ownership.native." + id, () => NativeAsync(id, root, alpha, beta, cancellationToken), results, "controlled-native").ConfigureAwait(false);
        }
        results.AddRange(unported.Select(p => new UnitResult("ownership." + p.Id, UnitStatus.Incomplete, 0,
            p.Evidence + " Not replaced by the separately counted compiled cases.")));
        return results;
    }

    private static async Task ExecuteAsync(string id, Func<Task> action, List<UnitResult> results, string group)
    {
        try
        {
            await action().ConfigureAwait(false);
            results.Add(new UnitResult(id, UnitStatus.Passed, 1, "Exact registered case completed; evidence kind=" + group, [group]));
        }
        catch (Exception failure)
        {
            results.Add(new UnitResult(id, UnitStatus.Failed, 1, failure.ToString(), [group]));
            if (failure.Data[OwnershipRetention.RequiredKey] is true)
                throw;
        }
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static T Reject<T>(Action action, string? prefix = null) where T : Exception
    {
        try { action(); }
        catch (T failure)
        {
            Require(prefix == null || failure.Message.StartsWith(prefix, StringComparison.Ordinal), "Wrong rejection: " + failure);
            return failure;
        }
        throw new InvalidOperationException("Expected rejection: " + typeof(T).Name);
    }

    private static async Task<T> RejectAsync<T>(Func<Task> action) where T : Exception
    {
        try { await action().ConfigureAwait(false); }
        catch (T failure) { return failure; }
        throw new InvalidOperationException("Expected rejection: " + typeof(T).Name);
    }

    private static JsonObject Request(string alpha, string title = "Alpha renamed") => new()
    {
        ["version"] = 2, ["kind"] = "request", ["requestID"] = RenameId,
        ["command"] = new JsonObject { ["graphCommand"] = new JsonObject
        {
            ["projectPath"] = alpha,
            ["command"] = new JsonObject { ["renameNode"] = new JsonObject { ["_0"] = MultiProjectPeer.AlphaNodeId, ["title"] = title } }
        } }
    };

    private static JsonObject ListRequest() => MultiProjectJson.Object(
        "{\"version\":2,\"kind\":\"request\",\"requestID\":\"" + ListId + "\",\"command\":{\"listRecentProjects\":{}}}");

    private static MultiProjectPeer Baseline(string alpha, string beta)
    {
        var peer = new MultiProjectPeer(alpha, beta);
        MultiProjectReply reply = peer.Request(ListRequest());
        peer.CompleteResponse(reply.Response!);
        foreach (string owner in new[] { alpha, beta }) peer.CompletePublication(peer.Publication(owner), "initial", ListId);
        return peer;
    }

    private static JsonObject Control(string alpha, string beta) => new()
    {
        ["token"] = Token, ["projectPath"] = alpha, ["nodeID"] = MultiProjectPeer.AlphaNodeId, ["title"] = "Alpha interleaved",
        ["selection"] = new JsonObject { ["projectPath"] = beta, ["nodeID"] = MultiProjectPeer.BetaNodeId, ["source"] = "synthetic-client" }
    };

    private static async Task ManagedAsync(string id, string root, string alpha, string beta)
    {
        if (id.StartsWith("quote-", StringComparison.Ordinal))
        {
            switch (id)
            {
                case "quote-empty": Require(OwnedChildSupervisor.QuoteArgument("") == "\"\"", "Empty argv was lost."); break;
                case "quote-trailing-slash": Require(OwnedChildSupervisor.QuoteArgument("a\\") == "\"a\\\\\"", "Trailing slash not doubled."); break;
                case "quote-embedded": Require(OwnedChildSupervisor.QuoteArgument("a\"b") == "\"a\\\"b\"", "Embedded quote not escaped."); break;
                case "quote-unicode": Require(OwnedChildSupervisor.QuoteArgument("\u03BB \uD83D\uDE80") == "\"\u03BB \uD83D\uDE80\"", "Unicode argv changed."); break;
                case "quote-nul": Reject<ArgumentException>(() => OwnedChildSupervisor.QuoteArgument("a\0b")); break;
            }
            return;
        }
        if (id.StartsWith("stream-", StringComparison.Ordinal))
        {
            if (id == "stream-independent-faults")
            {
                var first = new IOException("stdout original");
                var second = new IOException("stderr original");
                var failure = await RejectAsync<AggregateException>(() => OwnedChildSupervisor.RequireDrainAsync(
                    [Task.FromException<string>(first), Task.FromException<string>(second)], new Deadline(TimeSpan.FromSeconds(1)))).ConfigureAwait(false);
                Require(failure.InnerExceptions.Count == 2 && ReferenceEquals(failure.InnerExceptions[0], first) &&
                    ReferenceEquals(failure.InnerExceptions[1], second), "Independent original stream errors were replaced or omitted.");
                return;
            }
            if (id == "stream-shared-deadline")
            {
                var pending = new TaskCompletionSource<string>();
                var original = new IOException("stderr fails independently");
                var clock = Stopwatch.StartNew();
                var limit = new Deadline(TimeSpan.FromMilliseconds(100));
                await Task.Delay(60).ConfigureAwait(false);
                var failure = await RejectAsync<AggregateException>(() => OwnedChildSupervisor.RequireDrainAsync(
                    [pending.Task, Task.FromException<string>(original)], limit)).ConfigureAwait(false);
                Require(failure.InnerExceptions.Count == 2 && ReferenceEquals(failure.InnerExceptions[1], original) &&
                    clock.Elapsed < TimeSpan.FromSeconds(1), "Original shared deadline or independent stderr fault was lost.");
                return;
            }
            string text = id == "stream-surrogate-boundary" ? new string('a', 4095) + "\uD83D\uDE80tail" : "first\nsecond \u03BB \uD83D\uDE80\r\n";
            string path = Path.Combine(root, id + ".log");
            using var reader = new StreamReader(new MemoryStream(Encoding.UTF8.GetBytes(text)), new UTF8Encoding(false, true));
            string captured = await UiaOwnedStreamCapture.Read(reader, path).ConfigureAwait(false);
            Require(captured == text && File.ReadAllText(path, new UTF8Encoding(false, true)) == text &&
                File.ReadAllBytes(path).SequenceEqual(Encoding.UTF8.GetBytes(text)), "Raw UTF-8 bytes or streaming Unicode changed.");
            if (id == "stream-no-overwrite")
            {
                Reject<IOException>(() => UiaOwnedStreamCapture.Read(reader, path));
                Require(File.ReadAllText(path) == text, "Existing capture evidence overwritten.");
            }
            return;
        }
        if (id.StartsWith("receipt-", StringComparison.Ordinal))
        {
            string receiptRoot = Path.Combine(root, id);
            if (id is not ("receipt-missing" or "receipt-file" or "receipt-absent")) Directory.CreateDirectory(receiptRoot);
            if (id == "receipt-file") File.WriteAllText(receiptRoot, "not a directory");
            string path = Path.Combine(receiptRoot, "ownership-unproven.json");
            if (id == "receipt-existing") File.WriteAllText(path, "preserve-original");
            if (id is "receipt-duplicate-json" or "receipt-foreign-root" or "receipt-over-limit")
            {
                string json = id == "receipt-duplicate-json" ? "{\"schemaVersion\":1,\"schemaVersion\":1}" :
                    id == "receipt-over-limit" ? new string(' ', 4097) :
                    JsonSerializer.Serialize(new { schemaVersion = 1, validationRoot = root, reason = "ownership_unproven" });
                File.WriteAllText(path, json);
                Reject<InvalidDataException>(() => OwnershipRetention.ReceiptRequiresRetention(receiptRoot));
                return;
            }
            var failure = new IOException("original primary");
            OwnershipRetention.Tag(failure, id == "receipt-absent" ? null : receiptRoot);
            Require(failure.Data[OwnershipRetention.RequiredKey] is true && failure.Message == "original primary", "Boolean retention intent or original failure changed.");
            if (id == "receipt-valid") Require(OwnershipRetention.ReceiptRequiresRetention(receiptRoot), "Receipt not consumed.");
            else if (id == "receipt-existing")
                Require(File.ReadAllText(path) == "preserve-original" && failure.Data["GraphCodeValidationRetentionReceiptFailure"] != null, "Receipt overwrite or missing write-failure diagnostics.");
            else if (id != "receipt-absent") Require(failure.Data["GraphCodeValidationRetentionReceiptFailure"] != null, "Unwritable receipt silently accepted.");
            return;
        }
        if (id.StartsWith("proof-", StringComparison.Ordinal))
        {
            var proof = new OwnedCleanupProof(id != "proof-root-survivor", id != "proof-job-survivor",
                id != "proof-stdout-fault", id != "proof-stderr-fault", false);
            Require(proof.CanRelease == (id == "proof-success"), "UNKNOWN proof allowed resource release.");
            return;
        }
        if (id.StartsWith("cleanup-", StringComparison.Ordinal))
        {
            var authority = new FakeCleanupAuthority
            {
                RootExited = id is not ("cleanup-root-survivor" or "cleanup-primary-error"),
                JobEmpty = id != "cleanup-job-survivor",
                CloseFails = id is "cleanup-only-error" or "cleanup-later-actions",
                ConsumeDeadline = id == "cleanup-original-deadline"
            };
            if (id is "cleanup-stdout-fault" or "cleanup-both-stream-faults")
                authority.StandardOutput = Task.FromException<string>(new IOException("original stdout"));
            if (id == "cleanup-both-stream-faults")
                authority.StandardError = Task.FromException<string>(new IOException("original stderr"));
            if (id == "cleanup-original-deadline")
                authority.StandardOutput = new TaskCompletionSource<string>().Task;
            var primary = id == "cleanup-primary-error" ? new IOException("original primary") : null;
            OwnedCleanupProof? proof = null;
            if (id == "cleanup-success")
                proof = await OwnedCleanupCoordinator.CompleteAsync(authority, null, TimeSpan.FromSeconds(1)).ConfigureAwait(false);
            else if (primary != null)
            {
                proof = await OwnedCleanupCoordinator.CompleteAsync(authority, primary, TimeSpan.FromSeconds(1)).ConfigureAwait(false);
                Require(ReferenceEquals(authority.RetainedError, primary) && primary.Message == "original primary" &&
                    primary.Data["OwnedCleanupFailure"] is AggregateException, "Primary identity/secondary cleanup diagnostic changed.");
            }
            else
            {
                var failure = await RejectAsync<AggregateException>(() => OwnedCleanupCoordinator.CompleteAsync(authority, null,
                    TimeSpan.FromMilliseconds(id == "cleanup-original-deadline" ? 100 : 1000))).ConfigureAwait(false);
                proof = failure.Data["OwnedCleanupProof"] as OwnedCleanupProof;
                Require(ReferenceEquals(authority.RetainedError, failure), "Cleanup-only failure not retained by exact identity.");
                if (id == "cleanup-both-stream-faults")
                    Require(failure.InnerExceptions.Count == 2 && failure.InnerExceptions.All(e => e.InnerException is IOException),
                        "A failed stdout hid the independent stderr failure.");
            }
            Require(authority.Terminations == 1 && authority.JobWaits == 1 && authority.RootWaits == 1 &&
                ReferenceEquals(authority.JobDeadline, authority.RootDeadline), "Cleanup skipped a proof or refreshed its deadline.");
            bool closable = id is "cleanup-success" or "cleanup-only-error" or "cleanup-later-actions";
            Require(authority.Closes == (closable ? 2 : 0), "UNKNOWN allowed close or a close error skipped a later action.");
            Require(proof != null && proof.ResourcesClosed == (id == "cleanup-success") &&
                authority.Retained == (id != "cleanup-success"), "Cleanup resource/retention disposition changed.");
            if (id == "cleanup-original-deadline")
                Require(authority.RootRemainingMilliseconds < 50, "Root wait received a refreshed deadline after job wait.");
            return;
        }
        if (id.StartsWith("json-", StringComparison.Ordinal))
        {
            string text = id switch
            {
                "json-malformed" => "{", "json-duplicate" => "{\"x\":1,\"x\":2}",
                "json-nested-duplicate" => "{\"a\":[{\"x\":1,\"x\":2}]}",
                "json-array" => "[]", _ => "{\"x\":1,\"X\":2}"
            };
            if (id == "json-case-sensitive")
            {
                using var document = MultiProjectJson.Parse(text);
                Require(document.RootElement.EnumerateObject().Count() == 2, "Ordinal JSON property names collapsed.");
            }
            else Reject<InvalidDataException>(() => MultiProjectJson.Parse(text), "MULTIPROJECT_JSON");
            return;
        }
        if (id.StartsWith("frame-", StringComparison.Ordinal))
        {
            if (id == "frame-fragmented-unicode")
            {
                using var memory = new MemoryStream();
                await PipeFrames.WriteAsync(memory, "{\"text\":\"\u03BB \uD83D\uDE80\"}", new Deadline(TimeSpan.FromSeconds(1)), 7).ConfigureAwait(false);
                memory.Position = 0;
                using var fragmented = new FragmentedReadStream(memory, 1);
                using var doc = await PipeFrames.ReadAsync(fragmented, new Deadline(TimeSpan.FromSeconds(1))).ConfigureAwait(false);
                Require(doc!.RootElement.GetProperty("text").GetString() == "\u03BB \uD83D\uDE80", "UTF-8 framing text changed.");
                return;
            }
            byte[] bytes = id switch
            {
                "frame-clean-eof" => [], "frame-short-header" => [0, 0], "frame-short-body" => [0, 0, 0, 2, 123],
                "frame-zero" => [0, 0, 0, 0], "frame-over-limit" => [0, 32, 0, 1],
                "frame-invalid-utf8" => [0, 0, 0, 2, 0xc3, 0x28], _ => throw new InvalidOperationException(id)
            };
            using var source = new MemoryStream(bytes);
            if (id == "frame-clean-eof") Require(await PipeFrames.ReadAsync(source, new Deadline(TimeSpan.FromSeconds(1))) == null, "Clean EOF not distinct.");
            else if (id is "frame-short-header" or "frame-short-body")
                await RejectAsync<EndOfStreamException>(async () => { using var doc = await PipeFrames.ReadAsync(source, new Deadline(TimeSpan.FromSeconds(1))); }).ConfigureAwait(false);
            else if (id == "frame-invalid-utf8")
                await RejectAsync<DecoderFallbackException>(async () => { using var doc = await PipeFrames.ReadAsync(source, new Deadline(TimeSpan.FromSeconds(1))); }).ConfigureAwait(false);
            else await RejectAsync<InvalidDataException>(async () => { using var doc = await PipeFrames.ReadAsync(source, new Deadline(TimeSpan.FromSeconds(1))); }).ConfigureAwait(false);
            return;
        }
        PeerCase(id, alpha, beta);
    }

    private static void PeerCase(string id, string alpha, string beta)
    {
        var peer = Baseline(alpha, beta);
        JsonObject request = Request(alpha);
        if (id == "peer-positive-rename")
        {
            MultiProjectReply reply = peer.Request(request);
            peer.CompleteResponse(reply.Response!);
            JsonObject publication = peer.Publication(alpha);
            peer.CompletePublication(publication, "rename", RenameId);
            JsonObject snapshot = peer.Snapshot();
            Require(snapshot["appliedCount"]!.GetValue<int>() == 1 && snapshot["graphSequence"]!.GetValue<long>() == 3 &&
                snapshot["graphs"]![0]!["nodes"]![0]!["title"]!.GetValue<string>() == "Alpha renamed" &&
                snapshot["graphs"]![1]!["nodes"]![0]!["title"]!.GetValue<string>() == "Beta loop", "Rename crossed owner or sequence.");
            return;
        }
        if (id == "peer-resume-unchanged")
        {
            request["command"]!["graphCommand"]!["command"] = new JsonObject { ["resumeSession"] = new JsonObject { ["_0"] = MultiProjectPeer.AlphaNodeId } };
            string before = MultiProjectJson.Canonical(peer.Snapshot()["graphs"]);
            MultiProjectReply reply = peer.Request(request);
            Require(reply.PublishPath == null && MultiProjectJson.Canonical(peer.Snapshot()["graphs"]) == before &&
                peer.Snapshot()["appliedCount"]!.GetValue<int>() == 0, "Resume acknowledgement mutated graph.");
            return;
        }
        if (id.StartsWith("peer-control-", StringComparison.Ordinal))
        {
            JsonObject control = Control(alpha, beta);
            string prefix = "MULTIPROJECT_SCHEMA";
            switch (id)
            {
                case "peer-control-positive":
                    JsonObject frame = peer.Control(control);
                    peer.CompletePublication(frame, "control", Token);
                    Require(peer.Snapshot()["controls"]!.AsArray().Count == 1 && frame["sequence"]!.GetValue<long>() == 3, "Interleaved control not applied exactly once.");
                    return;
                case "peer-control-owner": control["projectPath"] = beta; control["nodeID"] = MultiProjectPeer.BetaNodeId; prefix = "MULTIPROJECT_OWNER"; break;
                case "peer-control-selection": control["selection"]!["nodeID"] = MultiProjectPeer.AlphaNodeId; prefix = "MULTIPROJECT_SELECTION"; break;
                case "peer-control-extra": control["extra"] = 1; break;
                case "peer-control-type": control["title"] = 7; prefix = "MULTIPROJECT_TYPE"; break;
                case "peer-control-duplicate": peer.Control(control); prefix = "MULTIPROJECT_DUPLICATE"; break;
                case "peer-control-second": peer.Control(control); control["token"] = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"; prefix = "MULTIPROJECT_ONE_SHOT"; break;
            }
            string before = MultiProjectJson.Canonical(peer.Snapshot());
            Reject<InvalidDataException>(() => peer.Control(control), prefix);
            Require(MultiProjectJson.Canonical(peer.Snapshot()) == before, "Rejected control mutated peer.");
            return;
        }
        if (id.StartsWith("peer-response-", StringComparison.Ordinal))
        {
            JsonObject response = peer.Request(request).Response!;
            string prefix = "MULTIPROJECT_CORRELATION";
            switch (id)
            {
                case "peer-response-unknown": response["requestID"] = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"; break;
                case "peer-response-extra": response["extra"] = 1; prefix = "MULTIPROJECT_SCHEMA"; break;
                case "peer-response-type": response["success"] = "true"; prefix = "MULTIPROJECT_TYPE"; break;
                case "peer-response-duplicate": peer.CompleteResponse(response); prefix = "MULTIPROJECT_DUPLICATE"; break;
            }
            Reject<InvalidDataException>(() => peer.CompleteResponse(response), prefix);
            return;
        }
        if (id == "peer-unanswered-publication")
        {
            peer.Request(request);
            Reject<InvalidDataException>(() => peer.CompletePublication(peer.Publication(alpha), "rename", RenameId), "MULTIPROJECT_UNANSWERED");
            return;
        }
        string expected = "MULTIPROJECT_SCHEMA";
        JsonNode rename = request["command"]!["graphCommand"]!["command"]!["renameNode"]!;
        switch (id)
        {
            case "peer-foreign-owner": request["command"]!["graphCommand"]!["projectPath"] = beta; expected = "MULTIPROJECT_OWNER"; break;
            case "peer-foreign-node": rename["_0"] = MultiProjectPeer.BetaNodeId; expected = "MULTIPROJECT_OWNER"; break;
            case "peer-missing-title": rename.AsObject().Remove("title"); break;
            case "peer-extra-field": rename["extra"] = 1; break;
            case "peer-title-type": rename["title"] = 7; expected = "MULTIPROJECT_TYPE"; break;
            case "peer-version-string": request["version"] = "2"; expected = "MULTIPROJECT_TYPE"; break;
            case "peer-version-bool": request["version"] = true; expected = "MULTIPROJECT_TYPE"; break;
            case "peer-request-id": request["requestID"] = "bad"; expected = "MULTIPROJECT_UUID"; break;
            case "peer-blank-title": rename["title"] = "  "; expected = "MULTIPROJECT_TITLE"; break;
            case "peer-request-duplicate": peer.Request(request); expected = "MULTIPROJECT_DUPLICATE"; break;
            default: throw new InvalidOperationException("Unimplemented managed case: " + id);
        }
        string original = MultiProjectJson.Canonical(peer.Snapshot());
        Reject<InvalidDataException>(() => peer.Request(request), expected);
        Require(MultiProjectJson.Canonical(peer.Snapshot()) == original, "Rejected request mutated peer.");
    }

    private static async Task NativeAsync(string id, string root, string alpha, string beta, CancellationToken cancellationToken)
    {
        string childRoot = Path.Combine(root, "native-" + id);
        Directory.CreateDirectory(childRoot);
        if (id == "real-pipe")
        {
            await RealPipeAsync(childRoot, alpha, beta, cancellationToken).ConfigureAwait(false);
            return;
        }
        string mode = id == "arguments-environment" ? "echo" : id;
        string[] arguments = ["space argument", "", "\"literal\"", "trailing\\", "\u03BB \uD83D\uDE80"];
        var start = OwnedFixture.Command(mode, childRoot, id == "arguments-environment" ? arguments : []);
        if (id == "arguments-environment")
        {
            start.Environment["OWNERSHIP_EMPTY"] = "";
            start.Environment.Remove("OWNERSHIP_ABSENT");
        }
        TimeSpan budget = TimeSpan.FromMilliseconds(id.Contains("timeout", StringComparison.Ordinal) ? 1500 : 5000);
        OwnedChildSupervisor child = OwnedChildSupervisor.Start(start, budget, childRoot);
        bool completionAttempted = false;
        try
        {
        if (id is "timeout" or "inherited-timeout" or "inherited")
        {
            var readyLimit = new Deadline(TimeSpan.FromSeconds(3));
            while (!File.Exists(Path.Combine(childRoot, "ready")))
            {
                if (readyLimit.Expired) throw new TimeoutException("Controlled root not ready.");
                await Task.Delay(10, cancellationToken).ConfigureAwait(false);
            }
        }
        if (id.Contains("timeout", StringComparison.Ordinal))
        {
            completionAttempted = true;
            Exception failure = await RejectAsync<Exception>(async () => { await child.CompleteAsync(cancellationToken); }).ConfigureAwait(false);
            Require(failure is TimeoutException or AggregateException && failure.Data["OwnedCleanupProof"] is OwnedCleanupProof { CanRelease: true, ResourcesClosed: true },
                "Timeout cleanup did not prove exact held root, empty job and both EOFs: " + failure);
            return;
        }
        if (id == "inherited")
        {
            var exitLimit = new Deadline(TimeSpan.FromSeconds(2));
            OwnedChildObservation observation = child.Observe();
            while (!observation.RootExited)
            {
                if (exitLimit.Expired) throw new TimeoutException("Controlled root exit not observed.");
                await Task.Delay(10, cancellationToken).ConfigureAwait(false);
                observation = child.Observe();
            }
            Require(observation.ActiveJobProcesses > 0 && !observation.StdoutCompleted && !observation.StderrCompleted,
                "Actual inherited-open-pipe/job condition was not exercised.");
            completionAttempted = true;
            OwnedCleanupProof proof = await child.StopAsync().ConfigureAwait(false);
            Require(proof is { CanRelease: true, ResourcesClosed: true }, "Inherited descendant cleanup unproved.");
            return;
        }
        completionAttempted = true;
        OwnedChildResult result = await child.CompleteAsync(cancellationToken).ConfigureAwait(false);
        Require(result.Cleanup is { CanRelease: true, ResourcesClosed: true }, "Native cleanup proof incomplete.");
        Require(result.ExitCode == (id == "abrupt" ? 23 : 0), "Controlled exit code changed.");
        if (id == "arguments-environment")
        {
            using var document = JsonDocument.Parse(result.StandardOutput);
            JsonElement record = document.RootElement;
            Require(record.GetProperty("arguments").EnumerateArray().Select(p => p.GetString()).SequenceEqual(arguments) &&
                record.GetProperty("present").GetBoolean() && record.GetProperty("value").GetString() == "" &&
                record.GetProperty("absent").GetBoolean() && record.GetProperty("cwd").GetString() == childRoot,
                "Native argv/empty-versus-absent environment/Unicode/cwd changed.");
        }
        else Require(result.StandardOutput.Contains("owned-capture-stdout \uD83D\uDE80", StringComparison.Ordinal) &&
            result.StandardError.Contains("owned-capture-stderr \u03BB", StringComparison.Ordinal), "Independent native stream content lost.");
        }
        catch (Exception primary)
        {
            if (!completionAttempted) await child.StopAsync(primary).ConfigureAwait(false);
            throw;
        }
    }

    private static async Task RealPipeAsync(string root, string alpha, string beta, CancellationToken cancellationToken)
    {
        string name = "graphcode-compiled-owned-" + Guid.NewGuid().ToString("N");
        var child = OwnedChildSupervisor.Start(OwnedFixture.Command("protocol", root, name, alpha, beta), TimeSpan.FromSeconds(10), root);
        Exception? primary = null;
        try
        {
            await using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            var deadline = new Deadline(TimeSpan.FromSeconds(5));
            await client.ConnectAsync(deadline.RemainingMilliseconds, cancellationToken).ConfigureAwait(false);
            await PipeFrames.WriteAsync(client, "{\"version\":2,\"kind\":\"hello\",\"supportedVersions\":[1,2]}", deadline, 7, cancellationToken).ConfigureAwait(false);
            using var hello = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            Require(hello!.RootElement.GetProperty("selectedVersion").GetInt32() == 2, "Real pipe v2 negotiation absent.");
            await PipeFrames.WriteAsync(client, ListRequest().ToJsonString(), deadline, 7, cancellationToken).ConfigureAwait(false);
            using var response = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            using var first = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            using var second = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            Require(response!.RootElement.GetProperty("requestID").GetString() == ListId &&
                first!.RootElement.GetProperty("sequence").GetInt32() == 1 && second!.RootElement.GetProperty("sequence").GetInt32() == 2 &&
                first.RootElement.GetProperty("event").GetProperty("graphChanged").GetProperty("project").GetProperty("path").GetString() == alpha &&
                second.RootElement.GetProperty("event").GetProperty("graphChanged").GetProperty("project").GetProperty("path").GetString() == beta,
                "Real fragmented two-owner publication differed.");
            await PipeFrames.WriteAsync(client, Request(alpha).ToJsonString(), deadline, 7, cancellationToken).ConfigureAwait(false);
            using var renamed = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            using var publication = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            Require(renamed!.RootElement.GetProperty("requestID").GetString() == RenameId &&
                publication!.RootElement.GetProperty("sequence").GetInt32() == 3, "Real rename correlation or sequence lost.");
            await PipeFrames.WriteAsync(client, Control(alpha, beta).ToJsonString(), deadline, 7, cancellationToken).ConfigureAwait(false);
            using var interleaved = await PipeFrames.ReadAsync(client, deadline, cancellationToken).ConfigureAwait(false);
            Require(interleaved!.RootElement.GetProperty("sequence").GetInt32() == 4 &&
                interleaved.RootElement.GetProperty("event").GetProperty("graphChanged").GetProperty("nodes")[0].GetProperty("title").GetString() == "Alpha interleaved",
                "Real interleaved Alpha publication missing.");
        }
        catch (Exception failure) { primary = failure; }
        try
        {
            OwnedChildResult result = await child.CompleteAsync(cancellationToken).ConfigureAwait(false);
            Require(result.ExitCode == 0 && result.Cleanup.ResourcesClosed, "Real peer cleanup failed: " + result.StandardError);
        }
        catch (Exception cleanup)
        {
            if (primary == null) throw;
            primary.Data["ProtocolCleanupFailure"] = cleanup;
            if (cleanup.Data[OwnershipRetention.RequiredKey] is true) OwnershipRetention.Tag(primary, root);
        }
        if (primary != null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(primary).Throw();
        using var receipt = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "peer.json")));
        Require(receipt.RootElement.GetProperty("requestCount").GetInt32() == 2 &&
            receipt.RootElement.GetProperty("responseCount").GetInt32() == 2 &&
            receipt.RootElement.GetProperty("publicationCount").GetInt32() == 4 &&
            receipt.RootElement.GetProperty("unansweredRequests").GetArrayLength() == 0, "Real peer receipt is incomplete.");
    }

    private sealed class FragmentedReadStream(Stream source, int maximum) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => source.Read(buffer, offset, Math.Min(count, maximum));
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            source.ReadAsync(buffer[..Math.Min(maximum, buffer.Length)], cancellationToken);
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class FakeCleanupAuthority : IOwnedCleanupAuthority
    {
        public string Identity => "controlled-fake-held-authority; nativeCalls=0";
        public Task<string>? StandardOutput { get; set; } = Task.FromResult("stdout");
        public Task<string>? StandardError { get; set; } = Task.FromResult("stderr");
        public bool RootExited = true, JobEmpty = true, CloseFails, ConsumeDeadline, Retained;
        public int Terminations, JobWaits, RootWaits, Closes, RootRemainingMilliseconds;
        public Deadline? JobDeadline, RootDeadline;
        public Exception? RetainedError;
        public void Terminate() => Terminations++;
        public async Task<bool> WaitForJobEmptyAsync(Deadline deadline)
        {
            JobWaits++;
            JobDeadline = deadline;
            if (ConsumeDeadline) await Task.Delay(75).ConfigureAwait(false);
            return JobEmpty;
        }
        public Task<bool> WaitForRootExitAsync(Deadline deadline)
        {
            RootWaits++;
            RootDeadline = deadline;
            RootRemainingMilliseconds = deadline.RemainingMilliseconds;
            return Task.FromResult(RootExited);
        }
        public IReadOnlyList<Action> CloseActions =>
        [
            () => { Closes++; if (CloseFails) throw new IOException("original first close failure"); },
            () => Closes++
        ];
        public void Retain(Exception failure)
        {
            Retained = true;
            RetainedError = failure;
            failure.Data[OwnershipRetention.RequiredKey] = true;
        }
    }
}
