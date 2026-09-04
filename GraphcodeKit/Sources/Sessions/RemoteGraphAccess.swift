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
/// verbs the briefing teaches — create, send, memo, status, artifactory — and says so
/// for the rest, rather than half-implementing all of them.
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

  /// Where the receipt for the last installed shim lives.
  ///
  /// **Named for the shim alone, and it covers the shim alone.** The briefing, wake
  /// digest and prompt ride in the same delivery but are *not* what this stamps: they
  /// change constantly (the wake digest on nearly every ensure), so hashing them would
  /// fire delivery every tick and defeat the point. They stay correct through the other
  /// half of the gate — a missing session always re-delivers
  /// (`ZmxSessionLauncher.deliveryFragment`). Anyone adding a file to the manifest
  /// should not assume this stamp speaks for it.
  ///
  /// One constant in the home-relative form both readers take: the installer expands it
  /// with `os.path.expanduser`, and the ensure dial's `cat` gets it from the remote
  /// shell's own tilde expansion. Two spellings of one path is exactly the drift that
  /// would leave the stamp permanently mismatched and re-deliver on every tick.
  public static let shimStampPath = "~/.graphcode/bin/.shim-stamp"

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
  ///
  /// `receipt` is a path and content written **after** every manifest entry has landed,
  /// as proof that the whole delivery succeeded.
  ///
  /// It cannot simply be another manifest entry. The comprehension is not transactional
  /// and iterates `sorted(m.items())`, where `.` (0x2E) sorts before `g` (0x67) — so a
  /// receipt at `~/.graphcode/bin/.shim-stamp` would be written *before*
  /// `~/.graphcode/bin/graphcode`, and any host whose shim write fails would end up
  /// claiming a CLI it never received. Permanently, too: the matching stamp then skips
  /// every later delivery, so the host can never be upgraded again.
  ///
  /// The trigger is a shim that can't be overwritten under a directory that can —
  /// a `graphcode` owned by another uid, a devcontainer feature's own copy, `chattr +i`.
  /// *Not* a full disk, though that was the first guess: on a genuinely full volume both
  /// writes fail and nothing is stranded, so it takes the freak case of enough free
  /// blocks for a 12-byte stamp but not a 31 KB shim.
  ///
  /// Ordering alone is sufficient — no `with`/`flush` bookkeeping — because a payload
  /// this size raises at `.write()` rather than at an implicit close, leaving no file
  /// behind and aborting the comprehension before the trailing statement is reached.
  ///
  /// No `makedirs` for the receipt: it is only reached once the shim it vouches for has
  /// been written, and that write created the directory.
  public static func installerScript(
    files: [String: String], receipt: (path: String, content: String)? = nil
  ) -> String? {
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
      + "for p,c in sorted(m.items())]; "
      + "len(sys.argv)>2 and open(os.path.expanduser(sys.argv[2]),'w').write(sys.argv[3])"
    var argv = ["python3", "-c", program, json.base64EncodedString()]
    if let receipt { argv += [receipt.path, receipt.content] }
    return argv.map(RemoteProjectLocation.shellQuoted).joined(separator: " ")
      + " >/dev/null 2>&1 || true"
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
    import unicodedata
    import uuid

    SESSION_PREFIX = "graphcode-"

    HELP = """graphcode (remote) -- drive the graph on the Mac these sessions belong to.

    USAGE
      graphcode projects
      graphcode status <project-path>
      graphcode node create <project-path> --title <t> --type <turn|goal|time|composite> [options]
      graphcode node stop <project-path> <node-id>
      graphcode node restart <project-path> <node-id>  kill its session, resume it in place
      graphcode node delete <project-path> <node-id>   irreversible; stop is reversible
      graphcode node send <project-path> <node-id> <message...>
      graphcode node memo <project-path> <node-id> <note...>
      graphcode artifactory post <project-path> [--topic <t>] <note...>
      graphcode artifactory sync <project-path> [--headlines] [--full] [--mark] [--json]
      graphcode artifactory read <project-path> <post-id>
      graphcode artifactory list <project-path> [--search <text>] [--json]
      graphcode artifactory watch <project-path> [--topic <t>] [--off]

    SAFETY
      Use `graphcode projects` to discover paths and `graphcode status` before retrying.
      `node stop` is reversible; `node delete` removes the node, edges, memory and
      session irreversibly. `--help` and `-h` only print help. The machine-wide
      `graphcode reap` recovery runs on the Mac, not this remote host: use it only there,
      and run `graphcode reap --dry-run` before the destructive form.

    ARTIFACTORY
      The shared board any loop can post to and any loop can read -- check it at the
      start of a pass. `sync` and `watch` are the calling loop's, so they need a
      session ($ZMX_SESSION); `list` and `read` are read-only and move no cursor. A
      large backlog prints as headlines and says so -- deep-read with `read <post-id>`.

    NODE OPTIONS
      --into <composite-id>  create inside that composite's sub-graph
      --check <text>         what a human verifies each turn (--type turn)
      --goal <text>          required for --type goal
      --predicate <cmd>      optional stop condition for --type goal (exit 0 = met)
      --prompt <text>        required for --type time or turn; a time loop's cadence
                             goes inside it (/loop 1h ...)
      --backend <name>       claudeCode | copilotCLI | codex | openCode
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
            key, value = self.wait_for(["graphChanged", "errorOccurred"])
            if key == "errorOccurred":
                fail(value["_0"])
            return value["_0"]

        def known_projects(self):
            self.send({"listRecentProjects": {}})
            _, value = self.wait_for(["recentProjectsListed"])
            return [p.get("path") for p in (value["_0"] or []) if p.get("path")]


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


    # The board's own arithmetic, ported from ArtifactoryKit rather than asked for over the
    # wire: `openProject`'s snapshot already carries every post and every reader's cursor, so
    # `read` and `list` send no command at all and `sync` prints from the snapshot it took
    # before advancing the cursor. RemoteCLIShimTests asserts this renderer byte-equal against
    # GraphcodeCommand's, which is the only thing that makes a second copy of it safe to have.
    TRIAGE_AFTER_POSTS = 12
    TRIAGE_AFTER_BYTES = 4096
    # Foundation encodes Date as seconds since 2001-01-01, not since the epoch.
    REFERENCE_DATE_OFFSET = 978307200
    # Spelled out rather than left to strftime("%b"), which follows the remote host's
    # LC_TIME; the Swift side pins en_US_POSIX.
    MONTH_ABBREVIATIONS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
                           "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
    EM_DASH = "\u2014"
    ELLIPSIS = "\u2026"
    HEADLINE_BUDGET = 80


    def artifactory_unread(posts, last_read):
        if last_read is None:
            return list(posts)
        return [post for post in posts if post.get("id", 0) > last_read]


    def artifactory_needs_triage(posts):
        if len(posts) > TRIAGE_AFTER_POSTS:
            return True
        weight = sum(len((post.get("body") or "").encode("utf-8")) for post in posts)
        return weight > TRIAGE_AFTER_BYTES


    def artifactory_cursor(graph, reader):
        # (cursor, the graph knows this reader). The distinction is the status line's: a
        # foreign or stale id gets the plain count, never "0 unread for you".
        for node in graph.get("nodes") or []:
            if str(node.get("id") or "").upper() == reader:
                return node.get("lastArtifactoryRead"), True
        return None, False


    def post_stamp(at):
        moment = time.localtime((at or 0) + REFERENCE_DATE_OFFSET)
        return "%s %d, %02d:%02d" % (MONTH_ABBREVIATIONS[moment.tm_mon - 1],
                                     moment.tm_mday, moment.tm_hour, moment.tm_min)


    def render_post(post):
        # Presence, not truthiness: Swift maps over the Optional, so a post whose topic
        # is the empty string renders " ()". The daemon refuses one today; matching the
        # Optional exactly is what keeps that a daemon rule rather than a second rule
        # this renderer would have to be re-audited against if it ever moved.
        topic = (" (%s)" % post["topic"]) if post.get("topic") is not None else ""
        return "#%s%s from %s at %s %s %s" % (
            post.get("id"), topic, post.get("author"), post_stamp(post.get("at")),
            EM_DASH, post.get("body") or "")


    def grapheme_clusters(text):
        # Swift measures and slices a String in extended grapheme clusters, Python in
        # code points, so `text[:80]` would cut a headline early -- 15 characters into a
        # body of decomposed accents, where the Mac cuts at 30 -- and could land between
        # a base character and its combining mark, ending the line on a mangled glyph.
        # This is UAX #29 reduced to the joins that actually reach a note: combining
        # marks, ZWJ sequences, variation selectors, skin-tone modifiers and flags. The
        # parity test drives each of them through both renderers.
        clusters = []
        joining = False
        flag_open = False
        for character in text:
            code = ord(character)
            regional = 0x1F1E6 <= code <= 0x1F1FF
            zero_width_joiner = code == 0x200D
            extends = (unicodedata.category(character) in ("Mn", "Mc", "Me")
                       or 0xFE00 <= code <= 0xFE0F
                       or 0xE0100 <= code <= 0xE01EF
                       or 0x1F3FB <= code <= 0x1F3FF)
            attaches = extends or zero_width_joiner or joining or (regional and flag_open)
            if clusters and attaches:
                clusters[-1] += character
            else:
                clusters.append(character)
            joining = zero_width_joiner
            flag_open = regional and not flag_open
        return clusters


    def render_headline(post):
        full = render_post(post).replace("\n", " ")
        clusters = grapheme_clusters(full)
        if len(clusters) <= HEADLINE_BUDGET:
            return full
        return "".join(clusters[:HEADLINE_BUDGET]) + ELLIPSIS


    def folded(text):
        # Swift's String.contains compares canonically, so "e" + U+0301 and U+00E9 match
        # there and would not here: Python's `in` is a code-point test. A body carrying
        # decomposed text -- which anything sourced from a macOS path routinely does --
        # would otherwise be findable from the Mac and invisible from the remote host,
        # which is the board reporting that mail does not exist.
        return unicodedata.normalize("NFC", (text or "").lower())


    def filtered_posts(posts, search):
        if not search:
            return posts
        needle = folded(search)
        return [post for post in posts
                if needle in folded(post.get("body"))
                or needle in folded(post.get("author"))
                or needle in folded(post.get("topic"))]


    def render_board(graph, reader=None, headlines=False, search=None, auto_triage=False):
        project = graph.get("project") or {}
        posts = graph.get("artifactory") or []
        if reader is not None:
            cursor, _ = artifactory_cursor(graph, reader)
            posts = artifactory_unread(posts, cursor)
        posts = filtered_posts(posts, search)
        if not posts:
            if search:
                if reader is None:
                    return "no posts match '%s'" % search
                return "no unread posts match '%s'" % search
            if reader is not None:
                return "no unread posts"
            return ("the board is empty %s post one: graphcode artifactory post "
                    "<project-path> <note%s>" % (EM_DASH, ELLIPSIS))
        triaged = auto_triage and artifactory_needs_triage(posts)
        label = "artifactory" if reader is None else "artifactory, unread"
        header = "%s %s: %d post%s" % (project.get("name", "?"), label, len(posts),
                                       "" if len(posts) == 1 else "s")
        if triaged:
            header += (" %s headlines only, that is a lot to read at once. Full text: "
                       "graphcode artifactory read %s <post-id>"
                       % (EM_DASH, project.get("path", "")))
        lines = [header]
        for post in posts:
            lines.append("  " + (render_headline(post) if headlines or triaged
                                 else render_post(post)))
        return "\n".join(lines)


    def iso8601(at):
        moment = time.gmtime((at or 0) + REFERENCE_DATE_OFFSET)
        return "%04d-%02d-%02dT%02d:%02d:%02dZ" % (
            moment.tm_year, moment.tm_mon, moment.tm_mday,
            moment.tm_hour, moment.tm_min, moment.tm_sec)


    def encoded_post(post):
        # What JSONEncoder makes of an ArtifactoryPost: absent rather than null for the
        # optionals, ISO-8601 for the date, and `kind` defaulted the way the hand-written
        # decoder defaults it for boards saved before records had their own quota.
        encoded = {"id": post.get("id"), "at": iso8601(post.get("at")),
                   "author": post.get("author"), "body": post.get("body"),
                   "kind": post.get("kind") or "note"}
        if post.get("authorID") is not None:
            encoded["authorID"] = post["authorID"]
        if post.get("topic") is not None:
            encoded["topic"] = post["topic"]
        return encoded


    def render_board_json(graph, reader=None, search=None):
        posts = graph.get("artifactory") or []
        last_read = None
        if reader is not None:
            last_read, _ = artifactory_cursor(graph, reader)
            posts = artifactory_unread(posts, last_read)
        board = {"posts": [encoded_post(post) for post in filtered_posts(posts, search)]}
        if last_read is not None:
            board["lastRead"] = last_read
        # Swift's JSONEncoder escapes forward slashes and emits non-ASCII raw; json.dumps
        # does neither by default. `/` cannot occur outside a string in JSON, so escaping
        # the dumped text wholesale is exact. A body carrying a path or a URL is what makes
        # this visible, which is why the parity fixture has one.
        encoded = json.dumps(board, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        return encoded.replace("/", "\\/")


    def artifactory_status_line(graph, reader):
        posts = graph.get("artifactory") or []
        if not posts:
            return None
        plural = "" if len(posts) == 1 else "s"
        cursor, known = artifactory_cursor(graph, reader) if reader else (None, False)
        if not known:
            return "artifactory: %d post%s" % (len(posts), plural)
        return "artifactory: %d post%s, %d unread for you" % (
            len(posts), plural, len(artifactory_unread(posts, cursor)))


    def render_posted(graph):
        posts = graph.get("artifactory") or []
        if not posts:
            return "posted"
        post = posts[-1]
        topic = (" (%s)" % post["topic"]) if post.get("topic") is not None else ""
        return "posted #%s%s" % (post.get("id"), topic)


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
        # The board rides last: one line, only when there is anything on it, so a
        # project that never touched the Artifactory renders as it always did. This is
        # the cheap "is there mail I should care about" check the briefing sends every
        # loop to `status` for, and the snapshot already holds everything it needs.
        board = artifactory_status_line(graph, self_node_id())
        if board:
            lines.append("  " + board)
        return "\n".join(lines)


    def graph_command(project, command):
        return {"graphCommand": {"projectPath": project, "command": command}}


    def normalized(path):
        parts = []
        for segment in path.split("/"):
            if not segment or segment == ".":
                continue
            if segment == "..":
                if parts:
                    parts.pop()
                continue
            parts.append(segment)
        return "/" + "/".join(parts)


    def remote_parts(project):
        # (host, path) for a project this daemon reaches over ssh, else (None, None).
        for scheme in ("ssh://", "codespace://"):
            if project.startswith(scheme):
                rest = project[len(scheme):]
                separator = rest.find("/")
                if separator < 1:
                    return None, None
                authority = rest[:separator].split("@")[-1].split(":")[0]
                return authority, normalized(rest[separator:])
        return None, None


    def this_host_names():
        names = [os.environ.get("CODESPACE_NAME", "")]
        try:
            names.append(os.uname().nodename)
        except Exception:
            pass
        return [name for name in names if name]


    def resolve_project(daemon, project):
        # A path spelled the way *this host* sees it -- the session's working directory,
        # its worktree -- named as the project it belongs to. The Mac keys graphs by the
        # ssh:// or codespace:// URI, and opening one is create-if-missing, so a local
        # spelling used to add a second project with the same name and put the loops in
        # there rather than in the graph the human is watching.
        if not project.startswith("/"):
            return project
        here = normalized(project)
        matches = []
        for known in daemon.known_projects():
            host, path = remote_parts(known)
            if path is None:
                continue
            if here == path or here.startswith(path.rstrip("/") + "/"):
                matches.append((known, host))
        if not matches:
            return project
        if len(matches) > 1:
            local = this_host_names()
            preferred = [match for match in matches if match[1] in local]
            if len(preferred) != 1:
                fail("%s is inside more than one project graphcode knows (%s). Name the "
                     "one you mean -- your briefing states it exactly."
                     % (project, ", ".join(sorted(match[0] for match in matches))))
            matches = preferred
        resolved = matches[0][0]
        sys.stderr.write("graphcode: %s is this host's path for %s\n" % (project, resolved))
        return resolved


    def run_and_print(project, inner=None):
        daemon = Daemon()
        project = resolve_project(daemon, project)
        graph = daemon.open_project(project)
        if inner is not None:
            daemon.send(graph_command(project, inner))
            key, value = daemon.wait_for(["graphChanged", "errorOccurred"])
            if key == "errorOccurred":
                fail(value["_0"])
            graph = value["_0"]
        print(render(graph))


    def run_with_verdict(project, inner, acknowledgement):
        daemon = Daemon()
        project = resolve_project(daemon, project)
        daemon.open_project(project)
        daemon.send(graph_command(project, inner))
        key, value = daemon.wait_for(["graphChanged", "errorOccurred"])
        if key == "errorOccurred":
            fail(value["_0"])
        print(acknowledgement)


    def run_and_report(project, inner, report):
        # `run_with_verdict` with the acknowledgement computed from the graph that comes
        # back rather than fixed in advance -- what `artifactory post` needs to name the
        # sequence number the note landed at.
        daemon = Daemon()
        project = resolve_project(daemon, project)
        daemon.open_project(project)
        daemon.send(graph_command(project, inner))
        key, value = daemon.wait_for(["graphChanged", "errorOccurred"])
        if key == "errorOccurred":
            fail(value["_0"])
        print(report(value["_0"]))


    def folded_title(raw):
        # The one-word CamelCase shape every loop name has -- LoopName.folded on the Mac.
        words = []
        for word in raw.split():
            start, end = 0, len(word)
            while start < end and not word[start].isalnum():
                start += 1
            while end > start and not word[end - 1].isalnum():
                end -= 1
            if end > start:
                words.append(word[start].upper() + word[start + 1:end])
        return "".join(words) or raw.strip()


    def make_draft(flags):
        if not flags.get("title"):
            fail("missing --title")
        if not flags.get("type"):
            fail("missing --type")
        types = {"main": "sketch", "sketch": "sketch",
                 "turn": "turnBased", "turnBased": "turnBased",
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
            "title": folded_title(flags["title"]),
            "loopType": loop_type,
            "pausesBeforeWritesOnly": False,
        }
        if flags.get("check"):
            draft["checkDescription"] = flags["check"]
        if flags.get("prompt"):
            draft["triggerPrompt"] = flags["prompt"]
            if loop_type in ("turnBased", "sketch"):
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
            if flags["backend"] not in ("claudeCode", "copilotCLI", "codex", "openCode"):
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


    ARTIFACTORY_FLAGS = {
        "post": ("topic",),
        "sync": ("headlines", "mark", "json", "full"),
        "read": (),
        "list": ("search", "json"),
        "watch": ("topic", "off"),
    }


    def artifactory_post_id(raw):
        # One-based by construction -- the daemon's ids start at 1 -- so "-7" is a typo,
        # never a post, and says so here rather than at the lookup.
        digits = raw[1:] if raw[:1] in ("+", "-") else raw
        if digits and all(character in "0123456789" for character in digits):
            value = int(raw)
            if value >= 1:
                return value
        fail("invalid value for post-id: %s" % raw)


    def artifactory(arguments):
        # Parsed in GraphcodeCommand.parseArtifactory's order -- subcommand, project path,
        # help anywhere, then the flags that subcommand allows -- so a mistyped flag is
        # refused here rather than silently ignored on the way to the daemon.
        if not arguments:
            fail("missing artifactory subcommand")
        subverb = arguments.pop(0)
        if wants_help(arguments):
            print(HELP)
            return
        if not arguments or arguments[0].startswith("--"):
            fail("missing project-path")
        project = arguments.pop(0)
        if any(argument in HELP_FLAGS for argument in arguments):
            print(HELP)
            return
        if subverb not in ARTIFACTORY_FLAGS:
            fail("unknown command: artifactory %s" % subverb)
        for argument in arguments:
            if argument.startswith("--") and argument[2:] not in ARTIFACTORY_FLAGS[subverb]:
                fail("unknown option: %s" % argument)
        flags = parse_flags(arguments)

        if subverb == "post":
            # The note is joined argv words, the node send/memo bargain. A trailing
            # `--topic` with no value goes with the flag: it was never the note's text.
            words = list(arguments)
            if "--topic" in words:
                index = words.index("--topic")
                del words[index:index + 2]
            text = " ".join(words).strip()
            if not text:
                fail("missing note")
            payload = {"text": text, "topic": flags.get("topic"), "from": self_node_id()}
            run_and_report(project, {"artifactoryPost": payload}, render_posted)
            return

        if subverb == "sync":
            reader = self_node_id()
            if not reader:
                fail("artifactory sync needs a loop identity %s run it from inside a loop's "
                     "session ($ZMX_SESSION); a human reading the board wants `graphcode "
                     "artifactory list`" % EM_DASH)
            daemon = Daemon()
            project = resolve_project(daemon, project)
            # Unread is computed from the snapshot taken *before* the cursor moves; reading
            # it afterwards would report every post as read. Same one-round-trip race the
            # Swift CLI documents and accepts.
            graph = daemon.open_project(project)
            daemon.send(graph_command(project, {"artifactorySync": {"from": reader}}))
            key, value = daemon.wait_for(["graphChanged", "errorOccurred"])
            if key == "errorOccurred":
                fail(value["_0"])
            headlines = "headlines" in flags
            full = "full" in flags
            if "json" in flags:
                print(render_board_json(graph, reader=reader))
            elif "mark" in flags:
                posts = graph.get("artifactory") or []
                latest = posts[-1].get("id", 0) if posts else 0
                if latest > 0:
                    print("marked read up to #%d" % latest)
                else:
                    print("marked read %s the board is empty" % EM_DASH)
            else:
                print(render_board(graph, reader=reader, headlines=headlines,
                                   auto_triage=not headlines and not full))
            return

        if subverb == "read":
            if not arguments or arguments[0].startswith("--"):
                fail("missing post-id")
            post_id = artifactory_post_id(arguments[0])
            daemon = Daemon()
            project = resolve_project(daemon, project)
            graph = daemon.open_project(project)
            for post in graph.get("artifactory") or []:
                if post.get("id") == post_id:
                    print(render_post(post))
                    return
            fail("no post #%d on this board %s `graphcode artifactory list %s` shows the "
                 "ids that exist" % (post_id, EM_DASH, project))

        if subverb == "list":
            daemon = Daemon()
            project = resolve_project(daemon, project)
            graph = daemon.open_project(project)
            if "json" in flags:
                print(render_board_json(graph, search=flags.get("search")))
            else:
                print(render_board(graph, search=flags.get("search")))
            return

        watcher = self_node_id()
        if not watcher:
            fail("artifactory watch needs a loop identity %s run it from inside a loop's "
                 "session ($ZMX_SESSION); the mail is delivered to the loop that watches"
                 % EM_DASH)
        on = "off" not in flags
        topic = flags.get("topic")
        if not on:
            acknowledgement = "stopped watching"
        elif topic is None:
            acknowledgement = ("watching all posts %s they are typed in when the loop goes "
                               "idle" % EM_DASH)
        else:
            acknowledgement = ("watching '%s' %s matching posts are typed in when the loop "
                               "goes idle" % (topic, EM_DASH))
        run_with_verdict(project, {"artifactoryWatch": {"on": on, "topic": topic,
                                                        "from": watcher}}, acknowledgement)

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
            run_and_print(arguments[0])
            return
        if verb == "artifactory":
            artifactory(arguments)
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
            run_and_print(project, create)
            return
        if subverb not in ("stop", "restart", "delete", "send", "memo"):
            fail("node %s runs from the Mac's own shell, not from a remote host" % subverb)
        if not arguments:
            fail("missing node-id")
        node_id = parse_uuid(arguments.pop(0), "node-id")
        if subverb == "stop":
            run_and_print(project, {"stopNode": {"_0": node_id}})
        elif subverb == "restart":
            run_and_print(project, {"restartNode": {"_0": node_id}})
        elif subverb == "delete":
            run_and_print(project, {"deleteNode": {"_0": node_id}})
        else:
            follow_up = False
            if subverb == "send" and arguments and arguments[0] == "--follow-up":
                follow_up = True
                arguments.pop(0)
            text = " ".join(arguments).strip()
            if not text:
                fail("missing %s" % ("message" if subverb == "send" else "note"))
            payload = {"_0": node_id, "text": text}
            sender = self_node_id()
            if sender:
                payload["from"] = sender
            if subverb == "send":
                if follow_up:
                    payload["followUp"] = True
                run_with_verdict(project, {"messageNode": payload},
                                 "accepted — typed in when the loop next goes idle"
                                 if follow_up else "delivered")
            else:
                run_with_verdict(project, {"memoNode": payload}, "noted")


    main(sys.argv[1:])
    """#
}
