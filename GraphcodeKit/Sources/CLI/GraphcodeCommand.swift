import Foundation

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
  case sendMessage(projectPath: String, nodeID: UUID, text: String)
  case updateNode(projectPath: String, nodeID: UUID, update: NodeUpdate)
  case memoNode(projectPath: String, nodeID: UUID, text: String)
  case pilotComposite(projectPath: String, nodeID: UUID)
  case armComposite(projectPath: String, nodeID: UUID)
  case usage(projectPath: String)

  public enum ParseError: Error, Equatable {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidValue(argument: String, value: String)
    case invalidDraft
  }

  public static let helpText = """
    graphcode — drive a graph of loops from the shell.

    USAGE
      graphcode projects
      graphcode status <project-path>
      graphcode node create <project-path> --title <t> --type <turn|goal|time|composite> [options]
      graphcode node stop <project-path> <node-id>
      graphcode node delete <project-path> <node-id>   removes it, its edges, session
                           and memory — irreversible; stop is the reversible verb
      graphcode node send <project-path> <node-id> <message…>
      graphcode node update <project-path> <node-id> [options]
      graphcode node memo <project-path> <node-id> <note…>
      graphcode node pilot <project-path> <node-id>     dry-run a composite
      graphcode node arm <project-path> <node-id>       arm it (needs a pilot first)
      graphcode edge create <project-path> <from-id> <to-id> [--kind <k>] [--condition <c>]
      graphcode usage <project-path>

    The reserved path graphcode://global addresses the always-resident global graph —
    the app's pinned "Graph" row — which every other verb accepts wherever
    <project-path> appears.

    NODE OPTIONS
      --into <composite-id>  create this loop *inside* that composite's sub-graph rather
                           than beside it — the CLI half of "add loops inside".
                           (`edge create` has its own --into; that one takes a project
                           path and only means anything on a --kind spawn.)
      --check <text>       what a human verifies each turn; optional
      --goal <text>        required for --type goal
      --predicate <cmd>    optional stop condition for --type goal (exit 0 = met)
      --prompt <text>      required for --type time; put the cadence in it (/loop 1h …)
      --backend <name>     claudeCode | copilotCLI | codex — default: run from inside a
                           loop, the creating loop's backend; otherwise claudeCode
      --model <tier>       fast | standard | capable           (default: by loop type)
      --metric <cmd>       how the loop's performance is measured — fed into its prompt
                           so it can score itself as it works, and sampled by graphcoded
                           once per cycle pass (last stdout line must be a number)
      --direction <d>      minimize | maximize                 (default: maximize)

    UPDATE OPTIONS (node update; pass only what changes)
      --goal, --predicate, --prompt, --check, --model, --metric, --direction as above
      --poll <seconds>     how often the predicate is polled
      --stall <seconds>    stall bound; 0 clears it
      A loop may not change its own --predicate: the verifier stays outside the
      verified. Session-facing changes reach a live session as a [graphcode] notice.

    node memo appends a note to the loop's own memory log — what the next pass reads
    before starting. Record dead ends and decisions, not a transcript.

    EDGE OPTIONS
      --kind <k>           handoff | message | spawn           (default: handoff)
      --condition <c>      always | onSuccess | onFailure      (default: always)
      --into <path>        spawn into a different project (--kind spawn only); this is
                           how the global graph dispatches work into a project

    EXIT CODES
      0   done
      1   bad usage, or graphcoded refused the command
      69  graphcoded unreachable — nothing was sent, so retrying is safe
      75  sent but never acknowledged — it may have been applied. Check `graphcode
          status` rather than re-running: create, send and memo are not idempotent.

    Everything talks to graphcoded, not to the app, so these work whether or not a
    window is open.
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
      return .listProjects

    case "status":
      return .status(projectPath: try take(&arguments, name: "project-path"))

    case "usage":
      return .usage(projectPath: try take(&arguments, name: "project-path"))

    case "node":
      let verb = try take(&arguments, name: "node subcommand")
      let path = try take(&arguments, name: "project-path")
      switch verb {
      case "create":
        var into: UUID?
        if let raw = parseFlags(arguments)["into"] {
          guard let id = UUID(uuidString: raw) else {
            throw ParseError.invalidValue(argument: "--into", value: raw)
          }
          into = id
        }
        return .createNode(projectPath: path, draft: try parseDraft(arguments), into: into)
      case "stop", "delete", "pilot", "arm", "send", "update", "memo":
        let raw = try take(&arguments, name: "node-id")
        guard let nodeID = UUID(uuidString: raw) else {
          throw ParseError.invalidValue(argument: "node-id", value: raw)
        }
        switch verb {
        case "pilot": return .pilotComposite(projectPath: path, nodeID: nodeID)
        case "arm": return .armComposite(projectPath: path, nodeID: nodeID)
        case "delete": return .deleteNode(projectPath: path, nodeID: nodeID)
        case "send":
          // Everything after the id is the message — joined rather than flagged, so
          // `graphcode node send <path> <id> tests are green, ship it` needs no quoting
          // gymnastics from the agent typing it.
          let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { throw ParseError.missingArgument("message") }
          return .sendMessage(projectPath: path, nodeID: nodeID, text: text)
        case "update":
          return .updateNode(projectPath: path, nodeID: nodeID, update: try parseUpdate(arguments))
        case "memo":
          // Joined like `send`, and for the same reason: a note should cost no quoting.
          let text = arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
          guard !text.isEmpty else { throw ParseError.missingArgument("note") }
          return .memoNode(projectPath: path, nodeID: nodeID, text: text)
        default: return .stopNode(projectPath: path, nodeID: nodeID)
        }
      default:
        throw ParseError.unknownCommand("node \(verb)")
      }

    case "edge":
      let verb = try take(&arguments, name: "edge subcommand")
      guard verb == "create" else { throw ParseError.unknownCommand("edge \(verb)") }
      let path = try take(&arguments, name: "project-path")
      let from = try takeUUID(&arguments, name: "from-id")
      let to = try takeUUID(&arguments, name: "to-id")
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
    let flags = parseFlags(arguments)
    if flags["help"] != nil { throw HelpRequested() }
    guard let title = flags["title"] else { throw ParseError.missingArgument("--title") }
    guard let rawType = flags["type"] else { throw ParseError.missingArgument("--type") }

    let loopType: LoopType
    switch rawType {
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

    let draft = NodeDraft(
      title: title,
      loopType: loopType,
      checkDescription: flags["check"],
      triggerPrompt: flags["prompt"],
      // A turn-based loop needs something to do. `--prompt` is what a caller already
      // types for a timed loop's opening instruction, so it means the same thing here
      // rather than making them learn a second flag for the same idea.
      firstInstruction: loopType == .turnBased ? flags["prompt"] : nil,
      goal: flags["goal"].map {
        GoalSpec(
          summary: $0, predicate: flags["predicate"],
          metricCommand: flags["metric"], metricDirection: metricDirection)
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

    let update = NodeUpdate(
      goalSummary: flags["goal"],
      goalPredicate: flags["predicate"],
      pollIntervalSeconds: pollIntervalSeconds,
      stallAfterSeconds: stallAfterSeconds,
      metricCommand: flags["metric"],
      metricDirection: metricDirection,
      triggerPrompt: flags["prompt"],
      checkDescription: flags["check"],
      modelTier: modelTier)
    guard !update.isEmpty else { throw ParseError.missingArgument("an option to change") }
    return update
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
          Usage is reported by the backend, never estimated — install a hook that runs
          `zmx set "$ZMX_SESSION" usage=inputTokens=…,outputTokens=…,costUSD=…`
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

  public static func describe(_ error: ParseError) -> String {
    switch error {
    case .unknownCommand(let name): return "unknown command: \(name)"
    case .missingArgument(let name): return "missing \(name)"
    case .invalidValue(let argument, let value): return "invalid value for \(argument): \(value)"
    case .invalidDraft:
      return "incomplete loop: a turn-based node needs --check, a goal-based one --goal, "
        + "a time-based one --prompt, and the backend must be able to host that type"
    }
  }
}
