import Foundation
import ArtifactoryKit

/// Argument parsing and output formatting for the `graphcode` CLI
/// (docs/03-architecture.md#cli-graphcode).
///
/// Lives in `GraphcodeKit` rather than in the CLI target's own sources so it's testable
/// from `graphcodeTests` without spawning the binary — the same reasoning that put
/// `GraphStore` here instead of inside `graphcoded`.
///
/// No third-party argument parser: the surface is a handful of verbs, and adding a
/// dependency to the one target that has to stay a plain command-line tool isn't worth
/// it for that.
public enum GraphcodeCommand: Equatable, Sendable {
  case help
  case listProjects
  case status(projectPath: String)
  /// `into` is the composite whose sub-graph the loop belongs in, when one was named —
  /// the command is the same, addressed at a nested graph instead of this one.
  case createNode(projectPath: String, draft: NodeDraft, into: UUID? = nil)
  case createEdge(projectPath: String, from: UUID, to: UUID, spec: EdgeSpec)
  case stopNode(projectPath: String, nodeID: UUID)
  case deleteNode(projectPath: String, nodeID: UUID)
  case sendMessage(projectPath: String, nodeID: UUID, text: String, followUp: Bool = false)
  case updateNode(projectPath: String, nodeID: UUID, update: NodeUpdate)
  /// Give a sketch a shape — the CLI half of the canvas's "Promote to…" menu. The
  /// promoter's identity is attributed at execution (`ZMX_SESSION`), not parsed here,
  /// matching how `updateNode` fills `updatedBy`.
  case promoteNode(projectPath: String, nodeID: UUID, promotion: SketchPromotion)
  case memoNode(projectPath: String, nodeID: UUID, text: String)
  /// Replace the loop's playbook (`NodeMemory.refinePlaybook`) — trailing words, or a
  /// whole file via `--file` since a playbook is a multi-line document and argv words
  /// arrive flattened. `--rollback` restores the previous version instead.
  case refineNode(projectPath: String, nodeID: UUID, text: String)
  case rollbackRefinement(projectPath: String, nodeID: UUID)
  case pilotComposite(projectPath: String, nodeID: UUID)
  case armComposite(projectPath: String, nodeID: UUID)
  case usage(projectPath: String)
  /// Kill `zmx` sessions no graph node in any workspace owns anymore — the on-demand
  /// recovery for PTY exhaustion (#197). No project path: orphanhood is a machine-wide
  /// question, and scoping it to one project is exactly the mistake that kills live
  /// sessions.
  case reap(dryRun: Bool)
  case exportNode(projectPath: String, nodeID: UUID, output: String, includeChildren: Bool = false)
  case exportGraph(projectPath: String, output: String)
  case importNodes(projectPath: String, fromZip: String, asChildOf: UUID? = nil)
  /// The Artifactory verbs (docs/03-architecture.md#cli-graphcode): the shared,
  /// unaddressed board any loop can write to and read. Attribution is not parsed —
  /// like `sendMessage`, the sender comes from `ZMX_SESSION` at execution.
  case artifactoryPost(projectPath: String, topic: String?, text: String)
  /// Read unread, then mark the board read — the cursor belongs to the calling loop,
  /// so this verb only means anything run from inside a session.
  case artifactorySync(projectPath: String)
  /// The whole board, read-only: no command reaches the daemon, no cursor moves.
  case artifactoryList(projectPath: String)
  /// Subscribe (`on: true`, `--topic` filters) or unsubscribe (`--off`) the calling
  /// loop; like `sync`, the subscription belongs to a loop, not a shell.
  case artifactoryWatch(projectPath: String, on: Bool, topic: String?)

  public enum ParseError: Error, Equatable {
    case unknownCommand(String)
    case unknownOption(String)
    case missingArgument(String)
    case invalidValue(argument: String, value: String)
    case invalidDraft
  }

  public static let helpText = """
    graphcode — drive a graph of loops from the shell.

    USAGE
      graphcode projects
      graphcode status <project-path>
      graphcode node create <project-path> --title <t> --type <main|turn|goal|time|composite> [options]
      graphcode node stop <project-path> <node-id>
      graphcode node delete <project-path> <node-id>   removes it, its edges, session
                           and memory — irreversible; stop is the reversible verb
      graphcode node send <project-path> <node-id> [--follow-up] <message…>
      graphcode node update <project-path> <node-id> [options]
      graphcode node promote <project-path> <node-id> --type <goal|turn|time> [options]
                           give a main loop a shape, keeping its session, edges and memory
      graphcode node memo <project-path> <node-id> <note…>
      graphcode node refine <project-path> <node-id> <playbook…|--file f|--rollback>
      graphcode node pilot <project-path> <node-id>     dry-run a composite
      graphcode node arm <project-path> <node-id>       arm it (needs a pilot first)
      graphcode edge create <project-path> <from-id> <to-id> [--kind <k>] [--condition <c>]
      graphcode artifactory post <project-path> [--topic <t>] <note…>
                           leave a note on the shared board for whoever comes next
      graphcode artifactory sync <project-path>
                           read your unread posts and mark the board read
      graphcode artifactory list <project-path>
                           the whole board, read-only — no cursor moves
      graphcode artifactory watch <project-path> [--topic <t>] [--off]
                           have matching posts typed into this loop's session as they
                           land; --off stops watching
      graphcode usage <project-path>
      graphcode reap [--dry-run]   recover suspected orphaned zmx sessions when PTYs
                           cannot be allocated or deleted loops leave sessions behind
      graphcode node export <project-path> <node-id> [--output file.zip] [--no-children]
                           packages the loop and everything descended from it — child
                           loops, sub-loops, session memory — into a shareable zip
      graphcode graph export <project-path> [--output file.zip]
      graphcode node import <project-path> <file.zip> [--as-child-of <parent-id>]
                           splices a bundle's loops in with fresh identities; name a
                           parent to hang them under an existing loop

    The reserved path graphcode://global addresses the always-resident global graph —
    the app's pinned "Graph" row — which every other verb accepts wherever
    <project-path> appears.

    RECOVERY AND SAFETY
      Use `graphcode projects` to discover project paths and `status` to inspect state
      before retrying a command. `GRAPHCODE_SUPPORT_DIR` selects the workspace for
      ordinary commands; `reap` is the exception: it reads every discovered workspace
      on this machine and queries zmx directly, so it also works when graphcoded is down.
      `graphcode reap --dry-run` is read-only and must be run first. Plain `reap` kills
      sessions that have no owner in any persisted graph, quick-chat store, or terminal
      layout; attached sessions are protected. Do not use reap for ordinary cleanup.
      `node stop` is reversible; `node delete` removes the node, edges, memory, and
      session irreversibly. `--help` and `-h` only print this help and never execute a
      command. Unknown options are errors; do not guess flag spellings.

    NODE OPTIONS
      --into <composite-id>  create this loop *inside* that composite's sub-graph rather
                           than beside it — the CLI half of "add loops inside".
                           (`edge create` has its own --into; that one takes a project
                           path and only means anything on a --kind spawn.)
      --check <text>       what a human verifies each turn; optional
      --goal <text>        required for --type goal
      --predicate <cmd>    optional stop condition for --type goal (exit 0 = met)
      --prompt <text>      required for --type time; put the cadence in it (/loop 1h …).
                           For --type main it is the optional starting note
      --heartbeat <secs>   for --type time, experimental: the daemon delivers the prompt
                           every interval instead of the prompt carrying /loop. Needs
                           "Daemon heartbeat" enabled in the app's Settings; the prompt
                           is then the bare task, no cadence in it
      --backend <name>     claudeCode | copilotCLI | codex | openCode — default: run from inside a
                           loop, the creating loop's backend; otherwise claudeCode
      --model <tier>       fast | standard | capable           (default: by loop type)
      --metric <cmd>       how the loop's performance is measured — fed into its prompt
                           so it can score itself as it works, and sampled by graphcoded
                           once per cycle pass (last stdout line must be a number)
      --direction <d>      minimize | maximize                 (default: maximize)
      --budget <tokens>    for --type goal: end the loop once its backend reports this
                           many tokens spent (input + output). Reported, never
                           estimated — a loop whose backend reports nothing is never
                           stopped by a budget
      --skip-unchanged     for --type goal: don't re-run the predicate while HEAD and
                           the dirty file list are unchanged since its last failure.
                           Only for predicates that depend on the tree — one that
                           watches CI or a deploy would never be re-asked

    UPDATE OPTIONS (node update; pass only what changes)
      --goal, --predicate, --prompt, --check, --model, --metric, --direction as above
      --poll <seconds>     how often the predicate is polled
      --stall <seconds>    stall bound; 0 clears it
      --budget <tokens>    token budget; 0 clears it
      --heartbeat <secs>   daemon heartbeat interval; 0 returns cadence to the prompt
      --skip-unchanged <true|false>
      A loop may not change its own --predicate or --budget: the verifier stays outside
      the verified. Session-facing changes reach a live session as a [graphcode] notice.

    SEND OPTIONS (node send)
      --follow-up          first word after the id: don't interrupt — the message is
                           staged to the loop's memory and typed into its session when
                           it next goes idle, instead of mid-turn

    PROMOTE OPTIONS (node promote; each target asks for its one decision)
      --type goal          with --goal <text> (required); --predicate, --metric,
                           --direction as above. A loop may not set its own
                           --predicate through promotion, the same rule update holds.
      --type turn          with --pause <every-turn|before-writes>  (default: every-turn)
      --type time          with --prompt <text> (required); put the cadence in it
      Promotion is one-way: a main loop gains a shape, never the reverse, and only a
      main loop can be promoted.

    node memo appends a note to the loop's own memory log — what the next pass reads
    before starting. Record dead ends and decisions, not a transcript.

    node refine replaces the loop's playbook — its own distilled method, carried into
    every wake ahead of the history. Whole document each time (--file for multi-line);
    the old version is snapshotted, --rollback restores it. A loop may refine itself;
    it still may not touch its goal, predicate, or budget.

    EDGE OPTIONS
      --kind <k>           handoff | message | spawn           (default: handoff)
      --condition <c>      always | onSuccess | onFailure      (default: always)
      --into <path>        spawn into a different project (--kind spawn only); this is
                           how the global graph dispatches work into a project

    MAILBOARD
      The shared, unaddressed board: `node send` reaches one peer you already know;
      a Artifactory post is a note for whoever comes next, discoverable by loops that
      did not exist when it was written. Run from inside a loop, posts are attributed
      to that loop (`ZMX_SESSION`, the same mechanism as `node send`); from a human's
      shell they read as from "a human". `sync` and `watch` need that loop identity —
      the read cursor and the subscription belong to a loop — so a human reads the
      board with `list`. A post is a note to a peer, not a transcript: 1 KB bound,
      and `--topic <t>` groups a thread (a watcher of a topic only hears matching
      posts; watched posts are delivered like a --follow-up message).


    EXIT CODES
      0   done
      1   bad usage, or graphcoded refused the command
      69  graphcoded unreachable — nothing was sent, so retrying is safe
      75  sent but never acknowledged — it may have been applied. Check `graphcode
          status` rather than re-running: create, send and memo are not idempotent.

    Everything talks to graphcoded, not to the app, so these work whether or not a
    window is open.

    COMMON WORKFLOWS
      graphcode projects
      graphcode status <project-path>
      graphcode node send <project-path> <node-id> --follow-up <message…>
                           stage work without interrupting an active turn
      graphcode artifactory sync <project-path>
                           check what other loops left for you before starting a pass
      graphcode artifactory post <project-path> --topic claims issue #12 is mine
                           stake a claim where every loop will find it, addressed to no one
      graphcode node pilot <project-path> <composite-id>
      graphcode node arm <project-path> <composite-id>
                           pilot before arming a proactive routine
      graphcode reap --dry-run
                           inspect suspected PTY orphans before any kill
    """

  public static func parse(_ arguments: [String]) throws -> GraphcodeCommand {
    do {
      return try parseVerb(arguments)
    } catch is HelpRequested {
      return .help
    }
  }

  /// Thrown from wherever `--help` turns up in place of the argument that was expected.
  /// `graphcode node create --help` used to fail with "missing project-path", because the
  /// only help check was on the first argument and everything after a verb was read
  /// positionally — so the one moment a caller admits they don't know the arguments was
  /// the one moment they were required to supply them.
  private struct HelpRequested: Error {}

  private static func isHelpFlag(_ argument: String) -> Bool {
    argument == "--help" || argument == "-h"
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func parseVerb(_ arguments: [String]) throws -> GraphcodeCommand {
    var arguments = arguments
    guard !arguments.isEmpty else { return .help }

    switch arguments.removeFirst() {
    case "help", "-h", "--help":
      return .help

    case "projects":
      try validateFlags(arguments, allowed: [])
      return .listProjects

    case "status":
      let path = try take(&arguments, name: "project-path")
      try validateFlags(arguments, allowed: [])
      return .status(projectPath: path)

    case "usage":
      let path = try take(&arguments, name: "project-path")
      try validateFlags(arguments, allowed: [])
      return .usage(projectPath: path)

    case "reap":
      if arguments.contains(where: isHelpFlag) { throw HelpRequested() }
      let flags = try parseReapFlags(arguments)
      return .reap(dryRun: flags["dry-run"] != nil)

    case "graph":
      let verb = try take(&arguments, name: "graph subcommand")
      guard verb == "export" else { throw ParseError.unknownCommand("graph \(verb)") }
      let path = try take(&arguments, name: "project-path")
      try validateFlags(arguments, allowed: ["help", "output"])
      let flags = parseFlags(arguments)
      if flags["help"] != nil { throw HelpRequested() }
      let output = flags["output"] ?? "\(path.split(separator: "/").last ?? "graph").zip"
      return .exportGraph(projectPath: path, output: output)

    case "node":
      let verb = try take(&arguments, name: "node subcommand")
      let path = try take(&arguments, name: "project-path")
      switch verb {
      case "export":
        return try parseNodeExport(&arguments, projectPath: path)

      case "import":
        return try parseNodeImport(&arguments, projectPath: path)

      case "create":
        var into: UUID?
        if let raw = parseFlags(arguments)["into"] {
          guard let id = UUID(uuidString: raw) else {
            throw ParseError.invalidValue(argument: "--into", value: raw)
          }
          into = id
        }
        return .createNode(projectPath: path, draft: try parseDraft(arguments), into: into)
      case "stop", "delete", "pilot", "arm", "send", "update", "memo", "promote", "refine":
        let raw = try take(&arguments, name: "node-id")
        guard let nodeID = UUID(uuidString: raw) else {
          throw ParseError.invalidValue(argument: "node-id", value: raw)
        }
        switch verb {
        case "pilot":
          try validateFlags(arguments, allowed: [])
          return .pilotComposite(projectPath: path, nodeID: nodeID)
        case "arm":
          try validateFlags(arguments, allowed: [])
          return .armComposite(projectPath: path, nodeID: nodeID)
        case "delete":
          try validateFlags(arguments, allowed: [])
          return .deleteNode(projectPath: path, nodeID: nodeID)
        case "promote":
          return .promoteNode(
            projectPath: path, nodeID: nodeID, promotion: try parsePromotion(arguments))
        case "send":
          // `--follow-up` is recognised only as the first word after the id, so it can
          // still be *sent* by putting it anywhere later in the message.
          var followUp = false
          if arguments.first == "--follow-up" {
            followUp = true
            arguments.removeFirst()
          }
          // Everything after the id is the message — joined rather than flagged, so
          // `graphcode node send <path> <id> tests are green, ship it` needs no quoting
          // gymnastics from the agent typing it.
          let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { throw ParseError.missingArgument("message") }
          return .sendMessage(projectPath: path, nodeID: nodeID, text: text, followUp: followUp)
        case "update":
          return .updateNode(projectPath: path, nodeID: nodeID, update: try parseUpdate(arguments))
        case "memo":
          // Joined like `send`, and for the same reason: a note should cost no quoting.
          let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { throw ParseError.missingArgument("note") }
          return .memoNode(projectPath: path, nodeID: nodeID, text: text)
        case "refine":
          return try parseRefine(arguments, projectPath: path, nodeID: nodeID)
        default:
          try validateFlags(arguments, allowed: [])
          return .stopNode(projectPath: path, nodeID: nodeID)
        }
      default:
        throw ParseError.unknownCommand("node \(verb)")
      }

    case "artifactory":
      return try parseArtifactory(&arguments)

    case "edge":
      let verb = try take(&arguments, name: "edge subcommand")
      guard verb == "create" else { throw ParseError.unknownCommand("edge \(verb)") }
      let path = try take(&arguments, name: "project-path")
      let from = try takeUUID(&arguments, name: "from-id")
      let to = try takeUUID(&arguments, name: "to-id")
      try validateFlags(arguments, allowed: ["help", "kind", "condition", "into"])
      let flags = parseFlags(arguments)
      if flags["help"] != nil { throw HelpRequested() }
      var spec = EdgeSpec()
      if let raw = flags["kind"] {
        guard let kind = EdgeKind(rawValue: raw) else {
          throw ParseError.invalidValue(argument: "--kind", value: raw)
        }
        spec.kind = kind
      }
      if let raw = flags["condition"] {
        guard let condition = EdgeCondition(rawValue: raw) else {
          throw ParseError.invalidValue(argument: "--condition", value: raw)
        }
        spec.condition = condition
      }
      // Only meaningful on a `.spawn` — the one edge kind allowed to cross graphs.
      // Accepted regardless of kind and simply ignored elsewhere would be worse than
      // refusing: a human who typed it meant something by it.
      if let target = flags["into"] {
        guard spec.kind == .spawn else {
          throw ParseError.invalidValue(argument: "--into", value: target)
        }
        spec.spawnTargetProjectPath = target
      }
      return .createEdge(projectPath: path, from: from, to: to, spec: spec)

    case let other:
      throw ParseError.unknownCommand(other)
    }
  }

  private static func parseDraft(_ arguments: [String]) throws -> NodeDraft {
    try validateFlags(
      arguments,
      allowed: [
        "help", "title", "type", "into", "check", "goal", "predicate", "prompt",
        "heartbeat", "backend", "model", "metric", "direction", "budget", "skip-unchanged",
      ])
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }
    guard let title = flags["title"] else { throw ParseError.missingArgument("--title") }
    guard let rawType = flags["type"] else { throw ParseError.missingArgument("--type") }

    let loopType: LoopType
    switch rawType {
    // `sketch` too, because that is the word every graph on disk still serialises and
    // what any script written before the rename still passes.
    case "main", "sketch": loopType = .sketch
    case "turn", "turnBased": loopType = .turnBased
    case "goal", "goalBased": loopType = .goalBased
    case "time", "timeBased": loopType = .timeBased
    // `proactive` too, because that is what a composite still serialises as and what a
    // human reading an existing graph off disk will have in front of them.
    case "composite", "proactive": loopType = .composite
    default: throw ParseError.invalidValue(argument: "--type", value: rawType)
    }

    // No flag means no choice — the draft travels with `backend: nil` and the daemon
    // resolves it: the creating loop's own backend when this command came from inside a
    // session, Claude Code otherwise. Hardcoding the default here was how a Copilot
    // loop's children came out as Claude Code loops.
    var backend: CLISessionBackendKind?
    if let raw = flags["backend"] {
      guard let parsed = CLISessionBackendKind(rawValue: raw) else {
        throw ParseError.invalidValue(argument: "--backend", value: raw)
      }
      backend = parsed
    }

    var modelTier: ModelTier?
    if let raw = flags["model"] {
      guard let parsed = ModelTier(rawValue: raw) else {
        throw ParseError.invalidValue(argument: "--model", value: raw)
      }
      modelTier = parsed
    }

    var metricDirection = MetricDirection.maximize
    if let raw = flags["direction"] {
      guard let parsed = MetricDirection(rawValue: raw) else {
        throw ParseError.invalidValue(argument: "--direction", value: raw)
      }
      metricDirection = parsed
    }

    var tokenBudget: Int?
    if let raw = flags["budget"] {
      guard let value = Int(raw), value > 0 else {
        throw ParseError.invalidValue(argument: "--budget", value: raw)
      }
      tokenBudget = value
    }
    let skipsUnchanged = try parseSkipUnchanged(flags) ?? false

    var heartbeat: Double?
    if let raw = flags["heartbeat"] {
      guard let value = Double(raw), value.isFinite, value > 0 else {
        throw ParseError.invalidValue(argument: "--heartbeat", value: raw)
      }
      heartbeat = value
    }

    let draft = NodeDraft(
      title: title,
      loopType: loopType,
      checkDescription: flags["check"],
      triggerPrompt: flags["prompt"],
      heartbeatIntervalSeconds: loopType == .timeBased ? heartbeat : nil,
      // A turn-based loop needs something to do. `--prompt` is what a caller already
      // types for a timed loop's opening instruction, so it means the same thing here
      // rather than making them learn a second flag for the same idea.
      // A sketch's `--prompt` is its optional starting note, the same reuse.
      firstInstruction: loopType == .turnBased || loopType == .sketch ? flags["prompt"] : nil,
      goal: flags["goal"].map {
        GoalSpec(
          summary: $0, predicate: flags["predicate"],
          metricCommand: flags["metric"], metricDirection: metricDirection,
          tokenBudget: tokenBudget, skipsUnchangedWorkspace: skipsUnchanged)
      },
      backend: backend,
      modelTier: modelTier)

    // The same validation the daemon applies, run early so the CLI can say what's
    // missing instead of exiting 0 on a command that quietly did nothing.
    guard draft.isValid else { throw ParseError.invalidDraft }
    return draft
  }

  /// The partial edit `node update` sends — only the flags present travel, so the
  /// daemon can tell "leave alone" (absent) from "clear" (empty string / 0).
  private static func parseUpdate(_ arguments: [String]) throws -> NodeUpdate {
    try validateFlags(
      arguments,
      allowed: [
        "help", "goal", "predicate", "poll", "stall", "metric", "direction", "budget",
        "heartbeat", "check", "model", "skip-unchanged", "prompt",
      ])
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }

    var pollIntervalSeconds: Double?
    if let raw = flags["poll"] {
      guard let value = Double(raw) else {
        throw ParseError.invalidValue(argument: "--poll", value: raw)
      }
      pollIntervalSeconds = value
    }
    var stallAfterSeconds: Double?
    if let raw = flags["stall"] {
      guard let value = Double(raw) else {
        throw ParseError.invalidValue(argument: "--stall", value: raw)
      }
      stallAfterSeconds = value
    }
    var metricDirection: MetricDirection?
    if let raw = flags["direction"] {
      guard let parsed = MetricDirection(rawValue: raw) else {
        throw ParseError.invalidValue(argument: "--direction", value: raw)
      }
      metricDirection = parsed
    }
    var modelTier: ModelTier?
    if let raw = flags["model"] {
      guard let parsed = ModelTier(rawValue: raw) else {
        throw ParseError.invalidValue(argument: "--model", value: raw)
      }
      modelTier = parsed
    }

    var tokenBudget: Int?
    if let raw = flags["budget"] {
      guard let value = Int(raw) else {
        throw ParseError.invalidValue(argument: "--budget", value: raw)
      }
      tokenBudget = value
    }
    var heartbeat: Double?
    if let raw = flags["heartbeat"] {
      guard let value = Double(raw), value.isFinite else {
        throw ParseError.invalidValue(argument: "--heartbeat", value: raw)
      }
      heartbeat = value
    }

    let update = NodeUpdate(
      goalSummary: flags["goal"],
      goalPredicate: flags["predicate"],
      pollIntervalSeconds: pollIntervalSeconds,
      stallAfterSeconds: stallAfterSeconds,
      metricCommand: flags["metric"],
      metricDirection: metricDirection,
      tokenBudget: tokenBudget,
      skipsUnchangedWorkspace: try parseSkipUnchanged(flags),
      triggerPrompt: flags["prompt"],
      heartbeatIntervalSeconds: heartbeat,
      checkDescription: flags["check"],
      modelTier: modelTier)
    guard !update.isEmpty else { throw ParseError.missingArgument("an option to change") }
    return update
  }

  /// `node refine`'s three spellings: `--rollback` restores the previous playbook,
  /// `--file <path>` sends a file's contents (a playbook is a multi-line document, and
  /// joined argv words arrive as one line), and trailing words send exactly what was
  /// typed. The file is read *here*, on the caller's machine, because the daemon may be
  /// serving a remote project whose filesystem has no such path.
  private static func parseRefine(
    _ arguments: [String], projectPath: String, nodeID: UUID
  ) throws -> GraphcodeCommand {
    if arguments.first == "--rollback" {
      return .rollbackRefinement(projectPath: projectPath, nodeID: nodeID)
    }
    if arguments.first == "--file" {
      guard arguments.count >= 2 else { throw ParseError.missingArgument("file path") }
      guard let text = try? String(contentsOfFile: arguments[1], encoding: .utf8),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw ParseError.invalidValue(argument: "--file", value: arguments[1])
      }
      return .refineNode(projectPath: projectPath, nodeID: nodeID, text: text)
    }
    let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { throw ParseError.missingArgument("playbook text") }
    return .refineNode(projectPath: projectPath, nodeID: nodeID, text: text)
  }

  /// `--skip-unchanged` — bare or `true` opts in, `false` opts back out, absent means
  /// "leave it alone" (create's caller defaults that to off).
  private static func parseSkipUnchanged(_ flags: [String: String]) throws -> Bool? {
    guard let raw = flags["skip-unchanged"] else { return nil }
    switch raw {
    case "", "true": return true
    case "false": return false
    default: throw ParseError.invalidValue(argument: "--skip-unchanged", value: raw)
    }
  }

  /// The one decision each target type needs — the same vocabulary `node create`
  /// already taught: `--goal`/`--predicate`/`--metric`/`--direction` for goal,
  /// `--prompt` for time. Turn's decision is where to pause, which create never asks
  /// (`--pause every-turn|before-writes`), defaulting to every turn like the app's form.
  private static func parsePromotion(_ arguments: [String]) throws -> SketchPromotion {
    try validateFlags(
      arguments,
      allowed: [
        "help", "type", "goal", "predicate", "metric", "direction", "pause", "prompt",
      ])
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }
    guard let rawType = flags["type"] else { throw ParseError.missingArgument("--type") }

    switch rawType {
    case "goal", "goalBased":
      guard let summary = flags["goal"] else { throw ParseError.missingArgument("--goal") }
      var metricDirection = MetricDirection.maximize
      if let raw = flags["direction"] {
        guard let parsed = MetricDirection(rawValue: raw) else {
          throw ParseError.invalidValue(argument: "--direction", value: raw)
        }
        metricDirection = parsed
      }
      return .goal(
        GoalSpec(
          summary: summary, predicate: flags["predicate"],
          metricCommand: flags["metric"], metricDirection: metricDirection))

    case "turn", "turnBased":
      switch flags["pause"] {
      case nil, "every-turn":
        return .turn(pausesBeforeWritesOnly: false)
      case "before-writes":
        return .turn(pausesBeforeWritesOnly: true)
      case .some(let raw):
        throw ParseError.invalidValue(argument: "--pause", value: raw)
      }

    case "time", "timeBased":
      guard let prompt = flags["prompt"] else { throw ParseError.missingArgument("--prompt") }
      return .timed(triggerPrompt: prompt)

    // `main` and `composite` are refused by shape, not by the daemon: demotion is
    // unrepresentable and a composite is not one decision (see `SketchPromotion`).
    default:
      throw ParseError.invalidValue(argument: "--type", value: rawType)
    }
  }

  /// `--name value` pairs. Bare positional arguments are ignored here; every caller has
  /// already consumed the positional ones it needs.
  private static func parseFlags(_ arguments: [String]) -> [String: String] {
    var flags: [String: String] = [:]
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      guard argument.hasPrefix("--") else {
        index += 1
        continue
      }
      let name = String(argument.dropFirst(2))
      if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
        flags[name] = arguments[index + 1]
        index += 2
      } else {
        flags[name] = ""
        index += 1
      }
    }
    return flags
  }

  private static func parseReapFlags(_ arguments: [String]) throws -> [String: String] {
    for argument in arguments where argument.hasPrefix("--") {
      guard argument == "--dry-run" else { throw ParseError.unknownOption(argument) }
    }
    return parseFlags(arguments)
  }

  private static func validateFlags(_ arguments: [String], allowed: Set<String>) throws {
    for argument in arguments where argument.hasPrefix("--") {
      let name = String(argument.dropFirst(2))
      guard allowed.contains(name) else { throw ParseError.unknownOption(argument) }
    }
  }

  /// Positional arguments only — never the trailing words of `node send`/`node memo`,
  /// which are joined rather than taken. That is what keeps `--help` meaning help here
  /// while staying literal text in a message somebody wants to transmit.
  private static func take(_ arguments: inout [String], name: String) throws -> String {
    if let first = arguments.first, isHelpFlag(first) { throw HelpRequested() }
    guard !arguments.isEmpty, !arguments[0].hasPrefix("--") else {
      throw ParseError.missingArgument(name)
    }
    return arguments.removeFirst()
  }

  private static func takeUUID(_ arguments: inout [String], name: String) throws -> UUID {
    let raw = try take(&arguments, name: name)
    guard let value = UUID(uuidString: raw) else {
      throw ParseError.invalidValue(argument: name, value: raw)
    }
    return value
  }
}

// MARK: - Output

extension GraphcodeCommand {
  /// A graph rendered for a terminal. Node ids are shown in full because they're what
  /// every other subcommand takes as input — a truncated id would look tidier and be
  /// useless.
  public static func render(_ graph: LoopGraph) -> String {
    var lines = ["\(graph.project.name)  (\(graph.aggregateState))"]
    if graph.nodes.isEmpty {
      lines.append("  no loops yet")
      return lines.joined(separator: "\n")
    }
    for node in graph.nodes {
      var line = "  \(node.id)  \(node.displayState)  \(node.loopType)  \(node.title)"
      if let reason = AttentionRollup.reason(for: node) {
        line += "  ← \(reason.displayName)"
      }
      lines.append(line)
    }
    if !graph.edges.isEmpty {
      lines.append("  edges:")
      for edge in graph.edges {
        let arrow = edge.fired ? "──▶" : "╌╌▶"
        let fromTitle = graph.nodes[id: edge.from]?.title ?? "?"
        let toTitle = graph.nodes[id: edge.to]?.title ?? "?"
        lines.append(
          "    \(fromTitle) \(arrow) \(toTitle)  [\(edge.kind.rawValue)/\(edge.condition.rawValue)]"
        )
      }
    }
    return lines.joined(separator: "\n")
  }

  /// The usage rollup, always stating its coverage. A bare total would read as the whole
  /// bill when it may be a fraction of one — graphcode only knows what a backend's hooks
  /// report, and a cost figure someone might act on has to say what it left out.
  public static func renderUsage(_ graph: LoopGraph) -> String {
    let coverage = graph.usageCoverage
    guard let usage = graph.usage else {
      return """
        \(graph.project.name): no usage reported (0/\(coverage.total) loops)
          Usage is reported by the backend, never estimated. Claude Code loops report it
          automatically at each turn end (graphcode's own Stop hook); a loop that has
          not finished a turn since that hook was installed has nothing to report yet.
          Other backends need a hook running
          `zmx set "$ZMX_SESSION" usage=input.<tokens>_output.<tokens>`
        """
    }
    var lines = ["\(graph.project.name): \(coverage.reporting)/\(coverage.total) loops reporting"]
    if let cost = usage.costUSD { lines.append(String(format: "  cost   $%.4f", cost)) }
    if let input = usage.inputTokens { lines.append("  input  \(input) tokens") }
    if let output = usage.outputTokens { lines.append("  output \(output) tokens") }
    for node in graph.nodes {
      guard let nodeUsage = node.usage else { continue }
      let cost = nodeUsage.costUSD.map { String(format: " $%.4f", $0) } ?? ""
      lines.append("    \(node.title)  \(nodeUsage.totalTokens ?? 0) tokens\(cost)")
    }
    return lines.joined(separator: "\n")
  }

  public static func render(_ projects: [ProjectRef]) -> String {
    guard !projects.isEmpty else { return "no projects yet" }
    return projects.map { "\($0.name)  \($0.path)" }.joined(separator: "\n")
  }

  /// The board for a terminal. `artifactory list` prints the whole thing (`reader`
  /// nil); `artifactory sync` passes the reading loop's id and prints only what its
  /// cursor has not covered — the subtraction is `Artifactory.unread`, the arithmetic
  /// the daemon's cursor contract rests on, so the CLI's "unread" and the store's can
  /// never disagree.
  public static func renderArtifactory(
    _ graph: LoopGraph, unreadFor readerID: UUID? = nil
  ) -> String {
    let posts: [ArtifactoryPost]
    if let readerID {
      posts = Artifactory.unread(
        in: graph.artifactory, since: graph.nodes[id: readerID]?.lastArtifactoryRead)
    } else {
      posts = graph.artifactory
    }
    guard !posts.isEmpty else {
      return readerID == nil
        ? "the board is empty — post one: graphcode artifactory post <project-path> <note…>"
        : "no unread posts"
    }
    let label = readerID == nil ? "artifactory" : "artifactory, unread"
    var lines = [
      "\(graph.project.name) \(label): \(posts.count) post\(posts.count == 1 ? "" : "s")"
    ]
    for post in posts { lines.append("  \(render(post))") }
    return lines.joined(separator: "\n")
  }

  /// One post, one line — the same identification the daemon's wake nudge quotes, so
  /// a loop reads a note the same way everywhere it meets one.
  public static func render(_ post: ArtifactoryPost) -> String {
    let topic = post.topic.map { " (\($0))" } ?? ""
    let stamp = post.at.formatted(date: .abbreviated, time: .shortened)
    return "#\(post.id)\(topic) from \(post.author) at \(stamp) — \(post.body)"
  }

  /// `artifactory post`'s answer — the sequence number is what the author's own log and
  /// any replier's `node send` can refer to the note by.
  public static func renderPosted(_ graph: LoopGraph) -> String {
    guard let post = graph.artifactory.last else { return "posted" }
    let topic = post.topic.map { " (\($0))" } ?? ""
    return "posted #\(post.id)\(topic)"
  }

  public static func describe(_ error: ParseError) -> String {
    switch error {
    case .unknownCommand(let name): return "unknown command: \(name)"
    case .unknownOption(let name): return "unknown option: \(name)"
    case .missingArgument(let name): return "missing \(name)"
    case .invalidValue(let argument, let value): return "invalid value for \(argument): \(value)"
    case .invalidDraft:
      return "incomplete loop: a turn-based node needs --check, a goal-based one --goal, "
        + "a time-based one --prompt, and the backend must be able to host that type"
    }
  }
}

/// The export/import verbs' parsing, split from the enum body the way `render` would
/// be next: `parseVerb` was over its length budget and the type over its own the day
/// these verbs landed, and each new verb after this should follow suit rather than
/// growing either.
extension GraphcodeCommand {
  fileprivate static func parseNodeExport(
    _ arguments: inout [String], projectPath: String
  ) throws -> GraphcodeCommand {
    let raw = try take(&arguments, name: "node-id")
    guard let nodeID = UUID(uuidString: raw) else {
      throw ParseError.invalidValue(argument: "node-id", value: raw)
    }
    try validateFlags(arguments, allowed: ["help", "output", "no-children", "children"])
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }
    let output = flags["output"] ?? "\(nodeID.uuidString).zip"
    // Children ride along by default — an exported coordinator without the loops it
    // fanned out isn't the workflow the human meant to share. `--children` is still
    // accepted as a no-op from when it was opt-in.
    let includeChildren = flags["no-children"] == nil
    return .exportNode(
      projectPath: projectPath, nodeID: nodeID, output: output, includeChildren: includeChildren)
  }

  fileprivate static func parseNodeImport(
    _ arguments: inout [String], projectPath: String
  ) throws -> GraphcodeCommand {
    let zipPath = try take(&arguments, name: "zip-file")
    try validateFlags(arguments, allowed: ["help", "as-child-of"])
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }
    var asChildOf: UUID?
    if let raw = flags["as-child-of"] {
      guard let id = UUID(uuidString: raw) else {
        throw ParseError.invalidValue(argument: "--as-child-of", value: raw)
      }
      asChildOf = id
    }
    return .importNodes(projectPath: projectPath, fromZip: zipPath, asChildOf: asChildOf)
  }

  /// The `artifactory` verbs' parsing, split from `parseVerb` the way export/import
  /// were. The note is joined argv words — the `node send`/`node memo` bargain, so
  /// `graphcode artifactory post <path> --topic claims issue #12 is mine` needs no
  /// quoting gymnastics — with `--topic <t>` riding along in either position.
  fileprivate static func parseArtifactory(
    _ arguments: inout [String]
  ) throws -> GraphcodeCommand {
    let verb = try take(&arguments, name: "artifactory subcommand")
    let path = try take(&arguments, name: "project-path")
    if arguments.contains(where: isHelpFlag) { throw HelpRequested() }
    switch verb {
    case "post":
      try validateFlags(arguments, allowed: ["topic"])
      let flags = parseFlags(arguments)
      // Strip the flag pair; a trailing `--topic` with no value goes too — it was
      // meant as the flag, never as the note's text, and dropping it lets the empty
      // note error say the real thing instead of echoing the flag back.
      var words = arguments
      if let index = words.firstIndex(of: "--topic") {
        words.removeSubrange(index...min(index + 1, words.count - 1))
      }
      let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { throw ParseError.missingArgument("note") }
      return .artifactoryPost(projectPath: path, topic: flags["topic"], text: text)

    case "sync":
      try validateFlags(arguments, allowed: [])
      return .artifactorySync(projectPath: path)

    case "list":
      try validateFlags(arguments, allowed: [])
      return .artifactoryList(projectPath: path)

    case "watch":
      try validateFlags(arguments, allowed: ["topic", "off"])
      let flags = parseFlags(arguments)
      return .artifactoryWatch(projectPath: path, on: flags["off"] == nil, topic: flags["topic"])

    default:
      throw ParseError.unknownCommand("artifactory \(verb)")
    }
  }
}
