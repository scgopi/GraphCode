using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace GraphCode.Validation.Ownership;

public sealed record MultiProjectReply(JsonObject? Response, string? PublishPath);

// The compiled controlled peer uses this same policy; suites never substitute a model.
public sealed class MultiProjectPeer
{
    public const string AlphaNodeId = "11111111-1111-4111-8111-111111111111";
    public const string BetaNodeId = "22222222-2222-4222-8222-222222222222";
    private readonly JsonArray graphs;
    private readonly JsonArray received = [], applied = [], answered = [], publications = [], controls = [];
    private long sequence;

    public MultiProjectPeer(string alphaPath, string betaPath)
    {
        foreach (string path in new[] { alphaPath, betaPath })
        {
            if (!Path.IsPathFullyQualified(path) || Path.GetFullPath(path) != path ||
                !Directory.Exists(path) || File.Exists(Path.Combine(path, ".git")) || Directory.Exists(Path.Combine(path, ".git")))
                throw new InvalidDataException("MULTIPROJECT_FIXTURE: require exact existing ordinary-folder paths");
        }
        if (string.Equals(alphaPath, betaPath, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("MULTIPROJECT_FIXTURE: owners must be different folders");
        graphs =
        [
            Graph("aaaaaaaa-1111-4111-8111-111111111111", alphaPath, "Alpha", AlphaNodeId),
            Graph("bbbbbbbb-2222-4222-8222-222222222222", betaPath, "Beta", BetaNodeId)
        ];
    }

    private static JsonObject Graph(string id, string path, string name, string nodeId) => new()
    {
        ["id"] = id, ["project"] = new JsonObject { ["path"] = path, ["name"] = name, ["remote"] = false },
        ["nodes"] = new JsonArray(new JsonObject
        {
            ["id"] = nodeId, ["title"] = name + " loop", ["loopType"] = "turnBased", ["state"] = "idle", ["activity"] = "stub",
            ["presence"] = new JsonObject { ["presence"] = "idle", ["confidence"] = "reported" }
        }),
        ["edges"] = new JsonArray()
    };

    private static string Text(JsonNode? value) => MultiProjectJson.String(value, "value");
    private static JsonObject Clone(JsonObject value) => (JsonObject)value.DeepClone();
    private static string OwnerPath(JsonNode graph) => Text(graph["project"]!["path"]);
    private static JsonNode Node(JsonNode graph) => graph["nodes"]![0]!;
    private JsonObject Find(JsonNode? path, string? node = null)
    {
        string exactPath = MultiProjectJson.String(path, "projectPath");
        JsonObject[] matches = graphs.OfType<JsonObject>().Where(g => OwnerPath(g) == exactPath).ToArray();
        if (matches.Length != 1 || (node != null && Text(Node(matches[0])["id"]) != node))
            throw new InvalidDataException("MULTIPROJECT_OWNER: wrong exact project/node owner");
        return matches[0];
    }

    public MultiProjectReply Request(JsonObject frame)
    {
        MultiProjectJson.Shape(frame, "request", "version", "kind", "requestID", "command");
        long version = MultiProjectJson.Integer(frame["version"], "version");
        string kind = MultiProjectJson.String(frame["kind"], "kind");
        if (version != 2 || kind != "request") throw new InvalidDataException("MULTIPROJECT_SCHEMA: expected v2 request");
        string id = MultiProjectJson.Uuid(frame["requestID"], "requestID");
        if (received.Any(r => Text(r!["requestID"]) == id))
            throw new InvalidDataException("MULTIPROJECT_DUPLICATE: requestID already received");
        if (frame["command"] is not JsonObject command || command.Count != 1)
            throw new InvalidDataException("MULTIPROJECT_SCHEMA: expected one command");
        string verb = command.First().Key;
        JsonObject? response = null, owner = null, rename = null;
        if (verb == "graphCommand")
        {
            JsonObject graphCommand = MultiProjectJson.Shape(command[verb], "graphCommand", "projectPath", "command");
            if (graphCommand["command"] is JsonObject inner && inner.ContainsKey("resumeSession"))
            {
                MultiProjectJson.Shape(inner, "graphCommand.command", "resumeSession");
                JsonObject resume = MultiProjectJson.Shape(inner["resumeSession"], "resumeSession", "_0");
                owner = Find(graphCommand["projectPath"], MultiProjectJson.Uuid(resume["_0"], "nodeID"));
            }
            else
            {
                JsonObject innerCommand = MultiProjectJson.Shape(graphCommand["command"], "graphCommand.command", "renameNode");
                rename = MultiProjectJson.Shape(innerCommand["renameNode"], "renameNode", "_0", "title");
                string nodeId = MultiProjectJson.Uuid(rename["_0"], "nodeID");
                MultiProjectJson.Title(rename["title"]);
                owner = Find(graphCommand["projectPath"], nodeId);
            }
            response = new JsonObject { ["version"] = 2, ["kind"] = "response", ["requestID"] = id, ["success"] = true };
        }
        else if (verb == "listRecentProjects")
        {
            MultiProjectJson.Shape(command[verb], verb);
            response = new JsonObject
            {
                ["version"] = 2, ["kind"] = "response", ["requestID"] = id,
                ["event"] = new JsonObject { ["recentProjectsListed"] = new JsonArray(graphs.Select(g => g!["project"]!.DeepClone()).ToArray()) }
            };
        }
        else if (verb is "listQuickChats" or "restoreOpenProjects" or "openGlobalGraph")
            MultiProjectJson.Shape(command[verb], verb);
        else if (verb == "openProject")
        {
            JsonObject open = MultiProjectJson.Shape(command[verb], verb, "path");
            Find(open["path"]);
        }
        else throw new InvalidDataException("MULTIPROJECT_SCHEMA: unsupported opt-in command " + verb);
        received.Add(new JsonObject { ["requestID"] = id, ["frame"] = frame.DeepClone(), ["expectedResponse"] = response?.DeepClone() });
        if (rename != null && owner != null)
        {
            applied.Add(new JsonObject
            {
                ["requestID"] = id, ["projectPath"] = OwnerPath(owner), ["nodeID"] = Text(rename["_0"]),
                ["beforeTitle"] = Text(Node(owner)["title"]), ["title"] = Text(rename["title"])
            });
            Node(owner)["title"] = Text(rename["title"]);
        }
        return new MultiProjectReply(response, rename == null ? null : OwnerPath(owner!));
    }

    public void CompleteResponse(JsonObject response)
    {
        MultiProjectJson.Shape(response, "response", "version", "kind", "requestID", response.ContainsKey("event") ? "event" : "success");
        if (MultiProjectJson.Integer(response["version"], "version") != 2 || Text(response["kind"]) != "response" ||
            (response.ContainsKey("success") && response["success"]?.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)))
            throw new InvalidDataException("MULTIPROJECT_TYPE: response version/kind/success types differ");
        string id = MultiProjectJson.Uuid(response["requestID"], "response.requestID");
        JsonNode[] matches = received.Where(r => Text(r!["requestID"]) == id).Select(r => r!).ToArray();
        if (matches.Length != 1) throw new InvalidDataException("MULTIPROJECT_CORRELATION: response has no unique request");
        if (answered.Any(r => Text(r!["requestID"]) == id)) throw new InvalidDataException("MULTIPROJECT_DUPLICATE: request already answered");
        if (matches[0]["expectedResponse"] != null &&
            MultiProjectJson.Canonical(matches[0]["expectedResponse"]) != MultiProjectJson.Canonical(response))
            throw new InvalidDataException("MULTIPROJECT_CORRELATION: reply differs from expected typed response");
        answered.Add(new JsonObject { ["requestID"] = id, ["response"] = response.DeepClone() });
    }

    public JsonObject Publication(string path)
    {
        JsonObject graph = Find(JsonValue.Create(path));
        return new JsonObject
        {
            ["version"] = 2, ["kind"] = "event", ["sequence"] = sequence + 1,
            ["event"] = new JsonObject { ["graphChanged"] = graph.DeepClone() }
        };
    }

    public void CompletePublication(JsonObject frame, string cause, string correlationId)
    {
        string path = Text(frame["event"]?["graphChanged"]?["project"]?["path"]);
        JsonObject expected = Publication(path);
        if (MultiProjectJson.Canonical(expected) != MultiProjectJson.Canonical(frame))
            throw new InvalidDataException("MULTIPROJECT_SEQUENCE: publication differs from exact next graph frame");
        if (cause != "control" && answered.Count(r => Text(r!["requestID"]) == correlationId) != 1)
            throw new InvalidDataException("MULTIPROJECT_UNANSWERED: publication precedes correlated response");
        sequence = MultiProjectJson.Integer(frame["sequence"], "sequence");
        publications.Add(new JsonObject { ["cause"] = cause, ["correlationID"] = correlationId, ["frame"] = frame.DeepClone() });
    }

    public JsonObject Control(JsonObject control)
    {
        MultiProjectJson.Shape(control, "publication control", "token", "projectPath", "nodeID", "title", "selection");
        string token = MultiProjectJson.Uuid(control["token"], "control.token");
        string node = MultiProjectJson.Uuid(control["nodeID"], "control.nodeID");
        if (controls.Any(c => Text(c!["token"]) == token)) throw new InvalidDataException("MULTIPROJECT_DUPLICATE: control token already used");
        if (controls.Count != 0) throw new InvalidDataException("MULTIPROJECT_ONE_SHOT: Alpha control was already applied");
        JsonObject graph = Find(control["projectPath"], node);
        if (OwnerPath(graph) != OwnerPath(graphs[0]!)) throw new InvalidDataException("MULTIPROJECT_OWNER: control must target Alpha");
        string title = MultiProjectJson.Title(control["title"]);
        JsonObject selection = MultiProjectJson.Shape(control["selection"], "selected Beta", "projectPath", "nodeID", "source");
        if (Text(selection["projectPath"]) != OwnerPath(graphs[1]!) ||
            Text(selection["nodeID"]) != BetaNodeId || Text(selection["source"]) is not ("live-uia" or "synthetic-client"))
            throw new InvalidDataException("MULTIPROJECT_SELECTION: expected exact observed Beta identity");
        if (received.Count <= 0 || answered.Count != received.Count || publications.Count < 2)
            throw new InvalidDataException("MULTIPROJECT_UNANSWERED: require positive settled request/publication baseline");
        foreach (JsonNode? owner in graphs)
            if (!publications.Any(p => Text(p!["cause"]) == "initial" &&
                Text(p["frame"]!["event"]!["graphChanged"]!["project"]!["path"]) == OwnerPath(owner!)))
                throw new InvalidDataException("MULTIPROJECT_PREREQUISITE: both owners must be published before interleaving");
        controls.Add(new JsonObject
        {
            ["token"] = token, ["projectPath"] = OwnerPath(graph), ["nodeID"] = node,
            ["beforeTitle"] = Text(Node(graph)["title"]), ["title"] = title, ["selection"] = selection.DeepClone()
        });
        Node(graph)["title"] = title;
        return Publication(OwnerPath(graph));
    }

    public JsonObject Snapshot() => new()
    {
        ["receivedCount"] = received.Count, ["requestCount"] = received.Count, ["responseCount"] = answered.Count,
        ["appliedCount"] = applied.Count, ["publicationCount"] = publications.Count, ["graphSequence"] = sequence,
        ["received"] = received.DeepClone(), ["applied"] = applied.DeepClone(), ["answered"] = answered.DeepClone(),
        ["publications"] = publications.DeepClone(), ["controls"] = controls.DeepClone(), ["graphs"] = graphs.DeepClone(),
        ["unansweredRequests"] = new JsonArray(received.Where(r => !answered.Any(a => Text(a!["requestID"]) == Text(r!["requestID"])))
            .Select(r => (JsonNode?)JsonValue.Create(Text(r!["requestID"]))).ToArray())
    };
}
