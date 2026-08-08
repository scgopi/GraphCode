import Foundation

/// What lets a session on a *remote* host use the graph the way a local one does: a
/// portable `graphcode` CLI shim, the home-relative paths it and the briefing land at
/// on that host, and the installer fragment that delivers them over the launch's own
/// ssh dial (issue #41 — before this, remote loops couldn't fan out at all).
///
/// **The shim is Python, not the Swift CLI, deliberately.** The real `graphcode` is a
/// macOS binary; the hosts remote projects live on mostly aren't Macs, and
/// cross-compiling GraphcodeKit for every remote platform would be a build system for
/// one file. python3 is already the launch path's scripting dependency (the Copilot
/// trust seed), it's validated at add-connection time the same way `zmx` is, and the
/// wire protocol it has to speak is four bytes of length plus JSON. The shim covers the
/// verbs the briefing teaches — create, send, memo, status — and says so for the rest,
/// rather than half-implementing all of them.
///
/// **Paths are `~/`-relative on purpose.** Nothing local knows the remote home
/// directory, and every consumer expands them on the remote host itself: the installer
/// through `os.path.expanduser`, argv paths through the remote login shell (see
/// `ZmxSessionLauncher.remoteQuotedCommand`).
public enum RemoteGraphAccess {
  /// Where the shim is installed on the remote host — the same place a local install
  /// puts the real CLI (`SessionBriefing.installedCLIPath`), so the briefing's "if it's
  /// not on your PATH" line stays true verbatim on both kinds of host.
  public static let cliInstallPath = "~/.graphcode/bin/graphcode"

  /// Where the stamp of the last delivered shim lives.
  ///
  /// One constant in the home-relative form both readers take: the installer expands it
  /// with `os.path.expanduser`, and the ensure dial's `cat` gets it from the remote
  /// shell's own tilde expansion. Two spellings of one path is exactly the drift that
  /// would leave the stamp permanently mismatched and re-deliver on every tick.
  public static let deliveryStampPath = "~/.graphcode/bin/.delivery-stamp"

  /// A content stamp for the shim, so an ensure can tell a host carrying the current CLI
  /// from one still carrying an older graphcode's.
  ///
  /// This exists because the shim is the one delivered file that is re-executed
  /// *throughout* a session's life rather than read once at startup: it speaks
  /// `FramedMessageIO` framing and `DaemonProtocol` JSON to this daemon, so a host left
  /// on an older copy breaks `graphcode node send` / `memo` / `resolve` for every loop
  /// already running there — silently, and for as long as those sessions live. Delivery
  /// therefore cannot simply be create-only like the hooks file.
  ///
  /// FNV-1a rather than a digest from CryptoKit: the question is only "same bytes or
  /// not", and Swift's own `hashValue` is seeded per process, so it would report a change
  /// on every daemon restart.
  public static var cliShimStamp: String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in cliShimSource.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  /// The remote twin of `SessionBriefing.directory(forProjectPath:)`.
  public static func briefingDirectory(forProjectPath projectPath: String) -> String {
    "~/.graphcode/briefings/\(SessionBriefing.slug(for: projectPath))"
  }

  public static func briefingPath(forProjectPath projectPath: String) -> String {
    briefingDirectory(forProjectPath: projectPath) + "/" + SessionBriefing.fileName
  }

  /// The remote twin of `NodeMemory.directory(forProjectPath:nodeID:)`. Only the wake
  /// digest is delivered there — the log itself stays on the Mac, where the daemon
  /// appends to it; the digest is the budgeted, rebuildable view of it.
  public static func memoryDirectory(forProjectPath projectPath: String, nodeID: UUID) -> String {
    "~/.graphcode/memory/\(SessionBriefing.slug(for: projectPath))/\(nodeID.uuidString)"
  }

  public static func wakePath(forProjectPath projectPath: String, nodeID: UUID) -> String {
    memoryDirectory(forProjectPath: projectPath, nodeID: nodeID) + "/" + NodeMemory.wakeFileName
  }

  /// Where an oversized prompt lands on the remote host — delivered like the wake
  /// digest, and for the same reason the briefing is: too long to type (issue #57).
  public static func promptPath(forProjectPath projectPath: String, nodeID: UUID) -> String {
    memoryDirectory(forProjectPath: projectPath, nodeID: nodeID) + "/" + NodeMemory.promptFileName
  }

  /// A shell fragment that lands `files` (home-relative path → content) on the remote
  /// host, or `nil` when there's nothing to send. One `python3 -c` with a base64 JSON
  /// manifest rather than heredocs or scp: a single argument survives every quoting
  /// layer between here and the remote shell, needs no extra ssh round-trip, and
  /// content can't collide with a delimiter. Neutered with `|| true` because delivery
  /// must never block the launch it precedes — a session without its briefing is the
  /// old behaviour, which works.
  public static func installerScript(files: [String: String]) -> String? {
    guard !files.isEmpty else { return nil }
    let manifest = files.mapValues { Data($0.utf8).base64EncodedString() }
    guard let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    else { return nil }
    let program =
      "import base64,json,os,sys; "
      + "m=json.loads(base64.b64decode(sys.argv[1])); "
      + "[(os.makedirs(os.path.dirname(os.path.expanduser(p)),exist_ok=True), "
      + "open(os.path.expanduser(p),'wb').write(base64.b64decode(c)), "
      + "os.chmod(os.path.expanduser(p),0o755) if p.endswith('/graphcode') else None) "
      + "for p,c in sorted(m.items())]"
    return [
      "python3", "-c", program, json.base64EncodedString(),
    ].map(RemoteProjectLocation.shellQuoted).joined(separator: " ") + " >/dev/null 2>&1 || true"
  }

  /// The remote `graphcode` CLI. It speaks `FramedMessageIO`'s framing and
  /// `DaemonProtocol`'s JSON over the unix socket `RemoteSocketForwarder` puts at the
  /// canonical `~/.graphcode/graphcoded.sock` — so it needs no configuration at all,
  /// though `GRAPHCODE_SOCKET` and `GRAPHCODE_SUPPORT_DIR` override the dial the same
  /// way they do locally. `RemoteCLIShimTests` pins the wire contract by running this
  /// very source against a Swift-decoded socket.
  public static let cliShimSource = #"""
    #!/usr/bin/env python3
    # The remote half of the `graphcode` CLI, delivered by the Mac that launched this
    # host's sessions (RemoteGraphAccess.swift is the source of truth). It speaks
    # graphcoded's framed-JSON protocol over the unix socket ssh forwards here -- a
    # deliberate subset: the verbs a loop needs to fan out, report back, and remember.
    import errno
    import json
    import os
    import socket
    import struct
    import sys
    import time
    import uuid

    SESSION_PREFIX = "graphcode-"

    HELP = """graphcode (remote) -- drive the graph on the Mac these sessions belong to.

    USAGE
      graphcode projects
      graphcode status <project-path>
      graphcode node create <project-path> --title <t> --type <turn|goal|time|composite> [options]
      graphcode node stop <project-path> <node-id>
      graphcode node delete <project-path> <node-id>   irreversible; stop is reversible
      graphcode node send <project-path> <node-id> <message...>
      graphcode node memo <project-path> <node-id> <note...>

    NODE OPTIONS
      --into <composite-id>  create inside that composite's sub-graph
      --check <text>         what a human verifies each turn (--type turn)
      --goal <text>          required for --type goal
      --predicate <cmd>      optional stop condition for --type goal (exit 0 = met)
      --prompt <text>        required for --type time or turn; a time loop's cadence
                             goes inside it (/loop 1h ...)
      --backend <name>       claudeCode | copilotCLI | codex
      --model <tier>         fast | standard | capable
      --metric <cmd>         performance measure; last stdout line must be a number
      --direction <d>        minimize | maximize (default: maximize)

    EXIT CODES
      0   done
      1   bad usage, or graphcoded refused the command
      69  graphcoded unreachable -- nothing was sent, so retrying is safe
      75  sent but never acknowledged -- it may have been applied. Check `graphcode
          status` rather than re-running: create, send and memo are not idempotent.

    <project-path> is this project's ssh:// path -- your briefing states it exactly.
    The remaining verbs (update, pilot, arm, edge, usage) run from the Mac's own shell."""


    # The same exit codes the Swift CLI uses, because a wrapper on either side of the ssh
    # link has to tell "you typed it wrong" from "graphcoded wasn't there" from "it may
    # well have been applied" -- only the middle one is safe to retry blindly, since
    # create/send/memo are not idempotent.
    EXIT_USAGE = 1
    EXIT_UNAVAILABLE = 69
    EXIT_AMBIGUOUS = 75


    def fail(message, code=EXIT_USAGE):
        sys.stderr.write("graphcode: %s\n" % message)
        sys.exit(code)


    def socket_path():
        override = os.environ.get("GRAPHCODE_SOCKET")
        if override:
            return os.path.expanduser(override)
        support = os.environ.get("GRAPHCODE_SUPPORT_DIR") or "~/.graphcode"
        support = os.path.expanduser(support)
        if not os.path.isabs(support):
            support = os.path.join(os.path.expanduser("~"), support)
        return os.path.join(support, "graphcoded.sock")


    # Dialling is retried; nothing past the first send is. Nothing has been written when a
    # dial fails, so a redial cannot duplicate a mutation. It matters more here than it
    # does on the Mac: this socket is an ssh forward, so it disappears and comes back
    # whenever the link is re-established, and a fan-out that happened to land in that
    # window used to fail outright.
    DIAL_ATTEMPTS = 4
    DIAL_BACKOFF = (0.05, 0.15, 0.35)
    RETRYABLE_DIAL_ERRNOS = (errno.ECONNREFUSED, errno.ENOENT, errno.EAGAIN, errno.EINTR)


    class Daemon:
        def __init__(self):
            path = socket_path()
            problem = None
            for attempt in range(DIAL_ATTEMPTS):
                if os.path.exists(path):
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.settimeout(10)
                    try:
                        sock.connect(path)
                        self.sock = sock
                        return
                    except OSError as error:
                        sock.close()
                        problem = error
                        if error.errno not in RETRYABLE_DIAL_ERRNOS:
                            break
                else:
                    problem = None
                if attempt < DIAL_ATTEMPTS - 1:
                    time.sleep(DIAL_BACKOFF[min(attempt, len(DIAL_BACKOFF) - 1)])
            if problem is None:
                fail("graphcoded isn't reachable at %s -- the ssh forward from the Mac "
                     "may be down; it returns when graphcode there next launches a loop "
                     "on this host." % path, EXIT_UNAVAILABLE)
            fail("couldn't reach graphcoded: %s" % problem, EXIT_UNAVAILABLE)

        def send(self, command):
            data = json.dumps(command).encode("utf-8")
            self.sock.sendall(struct.pack(">I", len(data)) + data)

        def read_exactly(self, count):
            data = b""
            while len(data) < count:
                chunk = self.sock.recv(count - len(data))
                if not chunk:
                    fail("graphcoded closed the connection before answering. The command "
                         "may still have been applied -- check with `graphcode status` "
                         "rather than re-running it.", EXIT_AMBIGUOUS)
                data += chunk
            return data

        def wait_for(self, keys, limit=64):
            for _ in range(limit):
                try:
                    length = struct.unpack(">I", self.read_exactly(4))[0]
                    event = json.loads(self.read_exactly(length).decode("utf-8"))
                except socket.timeout:
                    fail("timed out waiting for graphcoded to answer. The command may "
                         "still have been applied -- check with `graphcode status`.",
                         EXIT_AMBIGUOUS)
                for key in keys:
                    if isinstance(event, dict) and key in event:
                        return key, event[key]
            fail("graphcoded never acknowledged the command", EXIT_AMBIGUOUS)

        def open_project(self, path):
            self.send({"openProject": {"path": path}})
            _, value = self.wait_for(["graphChanged"])
            return value["_0"]


    def self_node_id():
        name = os.environ.get("ZMX_SESSION", "")
        if not name.startswith(SESSION_PREFIX):
            return None
        try:
            return str(uuid.UUID(name[len(SESSION_PREFIX):])).upper()
        except ValueError:
            return None


    def parse_uuid(raw, name):
        try:
            return str(uuid.UUID(raw)).upper()
        except ValueError:
            fail("invalid value for %s: %s" % (name, raw))


    def parse_flags(arguments):
        flags = {}
        index = 0
        while index < len(arguments):
            argument = arguments[index]
            if not argument.startswith("--"):
                index += 1
                continue
            name = argument[2:]
            if index + 1 < len(arguments) and not arguments[index + 1].startswith("--"):
                flags[name] = arguments[index + 1]
                index += 2
            else:
                flags[name] = ""
                index += 1
        return flags


    def render(graph):
        project = graph.get("project") or {}
        lines = [str(project.get("name", "?"))]
        nodes = graph.get("nodes") or []
        if not nodes:
            lines.append("  no loops yet")
        for node in nodes:
            state = node.get("state")
            if isinstance(state, dict):
                state = next(iter(state), "?")
            lines.append("  %s  %s  %s  %s" % (
                node.get("id"), state, node.get("loopType"), node.get("title")))
        return "\n".join(lines)


    def graph_command(project, command):
        return {"graphCommand": {"projectPath": project, "command": command}}


    def run_and_print(project, commands):
        daemon = Daemon()
        graph = daemon.open_project(project)
        for command in commands:
            daemon.send(command)
        if commands:
            _, value = daemon.wait_for(["graphChanged"])
            graph = value["_0"]
        print(render(graph))


    def run_with_verdict(project, command, acknowledgement):
        daemon = Daemon()
        daemon.open_project(project)
        daemon.send(command)
        key, value = daemon.wait_for(["graphChanged", "errorOccurred"])
        if key == "errorOccurred":
            fail(value["_0"])
        print(acknowledgement)


    def make_draft(flags):
        if not flags.get("title"):
            fail("missing --title")
        if not flags.get("type"):
            fail("missing --type")
        types = {"turn": "turnBased", "turnBased": "turnBased",
                 "goal": "goalBased", "goalBased": "goalBased",
                 "time": "timeBased", "timeBased": "timeBased",
                 "composite": "proactive", "proactive": "proactive"}
        if flags["type"] not in types:
            fail("invalid value for --type: %s" % flags["type"])
        loop_type = types[flags["type"]]
        required = {"turnBased": "prompt", "goalBased": "goal", "timeBased": "prompt"}
        needed = required.get(loop_type)
        if needed and not flags.get(needed):
            fail("a %s loop needs --%s" % (flags["type"], needed))
        draft = {
            "id": str(uuid.uuid4()).upper(),
            "title": flags["title"],
            "loopType": loop_type,
            "pausesBeforeWritesOnly": False,
        }
        if flags.get("check"):
            draft["checkDescription"] = flags["check"]
        if flags.get("prompt"):
            draft["triggerPrompt"] = flags["prompt"]
            if loop_type == "turnBased":
                draft["firstInstruction"] = flags["prompt"]
        if flags.get("goal"):
            direction = flags.get("direction", "maximize")
            if direction not in ("minimize", "maximize"):
                fail("invalid value for --direction: %s" % direction)
            goal = {"summary": flags["goal"], "pollIntervalSeconds": 60,
                    "metricDirection": direction}
            if flags.get("predicate"):
                goal["predicate"] = flags["predicate"]
            if flags.get("metric"):
                goal["metricCommand"] = flags["metric"]
            draft["goal"] = goal
        if flags.get("backend"):
            if flags["backend"] not in ("claudeCode", "copilotCLI", "codex"):
                fail("invalid value for --backend: %s" % flags["backend"])
            draft["backend"] = flags["backend"]
        if flags.get("model"):
            if flags["model"] not in ("fast", "standard", "capable"):
                fail("invalid value for --model: %s" % flags["model"])
            draft["modelTier"] = flags["model"]
        creator = self_node_id()
        if creator:
            draft["createdBy"] = creator
        return draft


    HELP_FLAGS = ("--help", "-h")


    def wants_help(arguments):
        # `--help` standing where an argument was expected asks for help, rather than being
        # the parse error that missing argument would otherwise be. Only ever checked
        # before a positional is consumed: the trailing words of send/memo are the message
        # itself, where `--help` is text somebody may well want to transmit.
        return bool(arguments) and arguments[0] in HELP_FLAGS


    def main(arguments):
        if not arguments or arguments[0] in ("help", "-h", "--help"):
            print(HELP)
            return
        verb = arguments.pop(0)
        if wants_help(arguments):
            print(HELP)
            return
        if verb == "projects":
            daemon = Daemon()
            daemon.send({"listRecentProjects": {}})
            _, value = daemon.wait_for(["recentProjectsListed"])
            projects = value["_0"]
            if not projects:
                print("no projects yet")
            for project in projects:
                print("%s  %s" % (project.get("name"), project.get("path")))
            return
        if verb == "status":
            if not arguments:
                fail("missing project-path")
            run_and_print(arguments[0], [])
            return
        if verb != "node":
            fail("unknown or Mac-only command: %s (see `graphcode help`)" % verb)
        if len(arguments) < 2:
            fail("missing node subcommand or project-path")
        subverb = arguments.pop(0)
        if wants_help(arguments):
            print(HELP)
            return
        project = arguments.pop(0)
        if subverb == "create":
            flags = parse_flags(arguments)
            if "help" in flags:
                print(HELP)
                return
            draft = make_draft(flags)
            create = {"createNode": {"_0": draft}}
            if flags.get("into"):
                into = parse_uuid(flags["into"], "--into")
                create = {"subGraphCommand": {"nodeID": into, "command": create}}
            run_and_print(project, [graph_command(project, create)])
            return
        if subverb not in ("stop", "delete", "send", "memo"):
            fail("node %s runs from the Mac's own shell, not from a remote host" % subverb)
        if not arguments:
            fail("missing node-id")
        node_id = parse_uuid(arguments.pop(0), "node-id")
        if subverb == "stop":
            run_and_print(project, [graph_command(project, {"stopNode": {"_0": node_id}})])
        elif subverb == "delete":
            run_and_print(project, [graph_command(project, {"deleteNode": {"_0": node_id}})])
        else:
            text = " ".join(arguments).strip()
            if not text:
                fail("missing %s" % ("message" if subverb == "send" else "note"))
            payload = {"_0": node_id, "text": text}
            sender = self_node_id()
            if sender:
                payload["from"] = sender
            if subverb == "send":
                run_with_verdict(project, graph_command(project, {"messageNode": payload}),
                                 "delivered")
            else:
                run_with_verdict(project, graph_command(project, {"memoNode": payload}),
                                 "noted")


    main(sys.argv[1:])
    """#
}
