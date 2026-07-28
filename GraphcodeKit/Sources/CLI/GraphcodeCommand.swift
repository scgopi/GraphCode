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
  case createNode(projectPath: String, draft: NodeDraft)
  case createEdge(projectPath: String, from: UUID, to: UUID, spec: EdgeSpec)
  case stopNode(projectPath: String, nodeID: UUID)
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
      graphcode node create <project-path> --title <t> --type <turn|goal|time> [options]
      graphcode node stop <project-path> <node-id>
      graphcode node pilot <project-path> <node-id>     dry-run a proactive composite
      graphcode node arm <project-path> <node-id>       arm it (needs a pilot first)
      graphcode edge create <project-path> <from-id> <to-id> [--kind <k>] [--condition <c>]
      graphcode usage <project-path>

    The reserved path graphcode://global addresses the always-resident global graph —
    the app's pinned "Graph" row — which every other verb accepts wherever
    <project-path> appears.

    NODE OPTIONS
      --check <text>       required for --type turn
      --goal <text>        required for --type goal
      --predicate <cmd>    optional stop condition for --type goal (exit 0 = met)
      --prompt <text>      required for --type time; put the cadence in it (/loop 1h …)
      --backend <name>     claudeCode | copilotCLI | codex     (default: claudeCode)
      --model <tier>       fast | standard | capable           (default: by loop type)

    EDGE OPTIONS
      --kind <k>           handoff | message | spawn           (default: handoff)
      --condition <c>      always | onSuccess | onFailure      (default: always)
      --into <path>        spawn into a different project (--kind spawn only); this is
                           how the global graph dispatches work into a project

    Everything talks to graphcoded, not to the app, so these work whether or not a
    window is open.
    """

  // swiftlint:disable:next cyclomatic_complexity
  public static func parse(_ arguments: [String]) throws -> GraphcodeCommand {
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
        return .createNode(projectPath: path, draft: try parseDraft(arguments))
      case "stop", "pilot", "arm":
        let raw = try take(&arguments, name: "node-id")
        guard let nodeID = UUID(uuidString: raw) else {
          throw ParseError.invalidValue(argument: "node-id", value: raw)
        }
        switch verb {
        case "pilot": return .pilotComposite(projectPath: path, nodeID: nodeID)
        case "arm": return .armComposite(projectPath: path, nodeID: nodeID)
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
    guard let title = flags["title"] else { throw ParseError.missingArgument("--title") }
    guard let rawType = flags["type"] else { throw ParseError.missingArgument("--type") }

    let loopType: LoopType
    switch rawType {
    case "turn", "turnBased": loopType = .turnBased
    case "goal", "goalBased": loopType = .goalBased
    case "time", "timeBased": loopType = .timeBased
    default: throw ParseError.invalidValue(argument: "--type", value: rawType)
    }

    var backend = CLISessionBackendKind.claudeCode
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

    let draft = NodeDraft(
      title: title,
      loopType: loopType,
      checkDescription: flags["check"],
      triggerPrompt: flags["prompt"],
      goal: flags["goal"].map { GoalSpec(summary: $0, predicate: flags["predicate"]) },
      backend: backend,
      modelTier: modelTier)

    // The same validation the daemon applies, run early so the CLI can say what's
    // missing instead of exiting 0 on a command that quietly did nothing.
    guard draft.isValid else { throw ParseError.invalidDraft }
    return draft
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

  private static func take(_ arguments: inout [String], name: String) throws -> String {
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
      var line = "  \(node.id)  \(node.state)  \(node.loopType.rawValue)  \(node.title)"
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
