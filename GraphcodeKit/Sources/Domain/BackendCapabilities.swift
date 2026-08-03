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
  /// Can it fan out to sub-agents itself — the thing a composite leans on.
  public var supportsSubAgents: Bool
  public var supportsMCP: Bool
  /// Can a message be injected into a live session? A backend that can't be interrupted
  /// mid-session can never be the `to` side of a `.message` edge, only `.handoff` or
  /// `.spawn`, which start a session rather than interrupt one
  /// (docs/02-graph-of-loops.md#inter-loop-messaging-in-practice).
  public var supportsMidSessionInput: Bool
  /// Can the *session itself* re-trigger its own work on a cadence — Claude Code's
  /// `/loop` and `/schedule`?
  ///
  /// This is what a time-based loop is actually built on: graphcode holds no interval of
  /// its own and deliberately never inspects the prompt (`LoopNode.triggerPrompt`), so
  /// the recurrence has to live inside the agent. A backend without it can still be
  /// handed a `/loop …` prompt — it will simply do the work once and stop, which looks
  /// like a broken schedule rather than an unsupported one. Hence its own capability
  /// rather than being inferred from something adjacent.
  public var supportsInSessionRecurrence: Bool

  public init(
    supportsGoalMode: Bool = false,
    supportsHooks: Bool = false,
    supportsStructuredOutput: Bool = false,
    supportsSubAgents: Bool = false,
    supportsMCP: Bool = false,
    supportsMidSessionInput: Bool = false,
    supportsInSessionRecurrence: Bool = false
  ) {
    self.supportsGoalMode = supportsGoalMode
    self.supportsHooks = supportsHooks
    self.supportsStructuredOutput = supportsStructuredOutput
    self.supportsSubAgents = supportsSubAgents
    self.supportsMCP = supportsMCP
    self.supportsMidSessionInput = supportsMidSessionInput
    self.supportsInSessionRecurrence = supportsInSessionRecurrence
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
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: true)

    case .copilotCLI:
      // Spiked against GitHub Copilot CLI 0.0.410 — every entry below was read off the
      // real `copilot --help`, not assumed.
      //
      // `--interactive <prompt>` is the one that matters: it starts an ordinary
      // attachable session that auto-runs a prompt, which is exactly graphcode's session
      // model. (`-p/--prompt` exists too but exits on completion, so it's the headless
      // shape graphcode deliberately moved away from.) `--model` is real, and includes
      // Claude and GPT families. MCP is first-class (`--additional-mcp-config`, built-in
      // github-mcp-server). It's a TUI in a PTY, so `zmx send` can type into it.
      //
      // `supportsHooks` stays false: no lifecycle-hook mechanism appears in its help, so
      // presence falls back to the heuristic rather than being reported.
      //
      // `supportsInSessionRecurrence` was false and is now true. It was set from the
      // interactive command list of 1.0.75, which has no `/loop` or `/schedule` — and a
      // time-based loop needs the *session* to re-trigger itself, since graphcode holds no
      // timer of its own. Copilot has since grown one. Worth knowing if a recurring loop
      // runs once and stops: that is the symptom of a Copilot too old to have it, and
      // `copilot help commands` on the machine running the loop is where to check.
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: false,
        supportsStructuredOutput: true,
        supportsSubAgents: false,
        supportsMCP: true,
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: true)

    case .codex:
      // Spiked against Codex CLI 0.145.0 — every entry read off the real `codex --help`,
      // and every uncertain one left false.
      //
      // Its launch shape is the same as Claude Code's: `codex [OPTIONS] [PROMPT]` opens an
      // interactive TUI with the prompt as a positional argument, which is exactly
      // graphcode's session model. (`codex exec` is the non-interactive shape, and the one
      // graphcode deliberately doesn't use.) MCP is first-class — `codex mcp` manages
      // external servers. It's a TUI in a PTY, so `zmx send` can type into it.
      //
      // The falses are the honest ones rather than the discouraging ones. Hooks exist in
      // some form (`--dangerously-bypass-hook-trust` implies a trust store for them), but
      // nothing in its help describes a lifecycle hook that could report presence the way
      // Claude Code's do, so presence stays heuristic. Sub-agent fan-out and a
      // `/loop`-equivalent aren't visible in the CLI surface at all; if either exists it
      // will be inside the TUI, and a capability claimed on a hunch is exactly what
      // `isSpiked` exists to prevent.
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: false,
        supportsStructuredOutput: false,
        supportsSubAgents: false,
        supportsMCP: true,
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: false)
    }
  }

  /// Whether anyone has actually verified this backend's row against the real CLI *and*
  /// written an adapter that can launch it.
  ///
  /// Until both are true the backend can host nothing at all. An earlier version let an
  /// unspiked backend take turn-based loops on the reasoning that they need nothing but
  /// "a session to type into" — which was wrong in a way that mattered: the app's
  /// terminal launches `claude` unconditionally
  /// (`GhosttyTerminalView.command`), so a loop labelled Codex opened a Claude Code
  /// session. Silently running a different agent than the one the picker says is worse
  /// than refusing, so this now gates every loop type.
  /// All three, now that Codex has an adapter and a row read off its real CLI (issue #1).
  /// Kept as a property rather than deleted: the *concept* is what stopped Codex being
  /// claimed as working for months, and the next backend added will need it again.
  public var isSpiked: Bool { true }

  /// Whether this backend can host that loop type at all. The refusal
  /// docs/04-cli-backends.md asks `OrchestratorClient` to make, kept next to the
  /// capability table it reads from.
  public func canHost(_ loopType: LoopType) -> Bool {
    // Nothing graphcode can't actually launch may host anything.
    guard isSpiked else { return false }
    switch loopType {
    case .turnBased:
      return true
    case .goalBased:
      return capabilities.supportsGoalMode
    case .timeBased:
      // The cadence lives inside the session, so this needs a backend whose agent can
      // re-trigger its own work. Without that a `/loop …` prompt runs once and stops,
      // which reads as a broken schedule rather than an unsupported one.
      return capabilities.supportsInSessionRecurrence
    case .composite:
      return capabilities.supportsSubAgents
    }
  }

  /// Backends that can host a given loop type, for the node form's picker.
  /// The backends worth offering as a *default* — the ones graphcode can actually launch.
  ///
  /// Narrower than `allCases` on purpose. `BackendPicker` still lists everything and
  /// greys out what can't host the chosen loop type, because there the question is "why
  /// can't I use Codex for this?" and a missing row wouldn't answer it. A settings picker
  /// asks a different question — "what should new loops use?" — and an option that would
  /// produce loops that never run is not an answer to it.
  public static var offerableAsDefault: [CLISessionBackendKind] {
    allCases.filter(\.isSpiked)
  }

  public static func hosting(_ loopType: LoopType) -> [CLISessionBackendKind] {
    allCases.filter { $0.canHost(loopType) }
  }
}
