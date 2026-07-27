/// What a CLI coding-agent backend can actually do — see
/// docs/04-cli-backends.md#clisessionbackend-protocol.
///
/// The point of naming these is refusal, not description: graphcode is explicitly *not*
/// trying to abstract the three backends into a common denominator
/// (docs/00-vision.md#non-goals). It exposes what each one really supports and lets a
/// loop's type constrain which backends can host it, so pairing a goal-based loop with a
/// backend that can't run to a stop condition is rejected at creation rather than
/// silently degraded into something weaker.
public struct BackendCapabilities: Codable, Equatable, Sendable {
  /// Can it run autonomously toward a stop condition, rather than turn by turn?
  public var supportsGoalMode: Bool
  /// Can graphcode install lifecycle hooks to read real presence, instead of falling
  /// back to scanning the terminal stream?
  public var supportsHooks: Bool
  public var supportsStructuredOutput: Bool
  /// Can it fan out to sub-agents itself — the thing a proactive composite leans on.
  public var supportsSubAgents: Bool
  public var supportsMCP: Bool
  /// Can a message be injected into a live session? A backend that can't be interrupted
  /// mid-session can never be the `to` side of a `.message` edge, only `.handoff` or
  /// `.spawn`, which start a session rather than interrupt one
  /// (docs/02-graph-of-loops.md#inter-loop-messaging-in-practice).
  public var supportsMidSessionInput: Bool

  public init(
    supportsGoalMode: Bool = false,
    supportsHooks: Bool = false,
    supportsStructuredOutput: Bool = false,
    supportsSubAgents: Bool = false,
    supportsMCP: Bool = false,
    supportsMidSessionInput: Bool = false
  ) {
    self.supportsGoalMode = supportsGoalMode
    self.supportsHooks = supportsHooks
    self.supportsStructuredOutput = supportsStructuredOutput
    self.supportsSubAgents = supportsSubAgents
    self.supportsMCP = supportsMCP
    self.supportsMidSessionInput = supportsMidSessionInput
  }
}

extension CLISessionBackendKind {
  public var displayName: String {
    switch self {
    case .claudeCode: return "Claude Code"
    case .copilotCLI: return "Copilot CLI"
    case .codex: return "Codex"
    }
  }

  /// docs/04-cli-backends.md's capability table. Claude Code is the reference backend —
  /// it's what graphcode itself is built in, so its row is known rather than assumed.
  ///
  /// The other two rows are deliberately conservative: every entry the doc marks `TBD`
  /// is `false` here, not a guess. A capability wrongly claimed produces a loop that
  /// silently misbehaves; one wrongly denied only makes a backend unavailable for a loop
  /// type, which is visible and easy to correct once someone has actually spiked the CLI
  /// (docs/07-roadmap.md#phase-5--multi-backend). `isSpiked` is what marks that
  /// difference honestly in the UI rather than hiding it.
  public var capabilities: BackendCapabilities {
    switch self {
    case .claudeCode:
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: true,
        supportsStructuredOutput: true,
        supportsSubAgents: true,
        supportsMCP: true,
        supportsMidSessionInput: true)
    case .copilotCLI, .codex:
      return BackendCapabilities()
    }
  }

  /// Whether anyone has actually verified this backend's row against the real CLI.
  /// Until then it hosts turn-based loops only — the one loop type that needs nothing
  /// from a backend beyond a session to type into.
  public var isSpiked: Bool { self == .claudeCode }

  /// Whether this backend can host that loop type at all. The refusal
  /// docs/04-cli-backends.md asks `OrchestratorClient` to make, kept next to the
  /// capability table it reads from.
  public func canHost(_ loopType: LoopType) -> Bool {
    switch loopType {
    case .turnBased:
      return true
    case .goalBased:
      return capabilities.supportsGoalMode
    case .timeBased:
      // The cadence lives inside the session as a `/loop` directive, so this needs a
      // backend with a real skill vocabulary rather than one that merely accepts a
      // prompt — which is what `supportsStructuredOutput` stands in for until each CLI
      // is spiked.
      return capabilities.supportsStructuredOutput
    case .proactive:
      return capabilities.supportsSubAgents
    }
  }

  /// Backends that can host a given loop type, for the node form's picker.
  public static func hosting(_ loopType: LoopType) -> [CLISessionBackendKind] {
    allCases.filter { $0.canHost(loopType) }
  }
}
