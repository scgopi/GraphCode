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
  /// A time-based loop may instead use graphcode's daemon cadence, represented by
  /// `supportsDaemonRecurrence`. A backend with neither capability cannot host one.
  public var supportsInSessionRecurrence: Bool
  public var supportsDaemonRecurrence: Bool
  /// The in-session directive that arms the backend's *own* stop-condition check —
  /// `/goal <condition>`, which sets a session-scoped hook that keeps the agent working
  /// until a separate evaluator says the condition holds. The goal-based counterpart of
  /// `/loop`, and it earns its place for the same reason: a goal stated as prose is an
  /// instruction the agent may consider discharged after one pass, while a goal stated
  /// as the directive is checked by the CLI every time the agent tries to stop.
  ///
  /// Every backend graphcode drives has grown the command, so every row now carries it.
  /// The field stays a per-backend `String?` rather than collapsing into a constant for
  /// the same reason `isSpiked` did: `nil` is what a backend arriving without the command
  /// needs, and a session handed a directive its CLI does not have types the arming step
  /// as literal prose — a goal loop that looks armed and is not.
  public var goalDirective: String?

  public init(
    supportsGoalMode: Bool = false,
    supportsHooks: Bool = false,
    supportsStructuredOutput: Bool = false,
    supportsSubAgents: Bool = false,
    supportsMCP: Bool = false,
    supportsMidSessionInput: Bool = false,
    supportsInSessionRecurrence: Bool = false,
    supportsDaemonRecurrence: Bool = false,
    goalDirective: String? = nil
  ) {
    self.supportsGoalMode = supportsGoalMode
    self.supportsHooks = supportsHooks
    self.supportsStructuredOutput = supportsStructuredOutput
    self.supportsSubAgents = supportsSubAgents
    self.supportsMCP = supportsMCP
    self.supportsMidSessionInput = supportsMidSessionInput
    self.supportsInSessionRecurrence = supportsInSessionRecurrence
    self.supportsDaemonRecurrence = supportsDaemonRecurrence
    self.goalDirective = goalDirective
  }
}

extension CLISessionBackendKind {
  public var displayName: String {
    switch self {
    case .claudeCode: return "Claude Code"
    case .copilotCLI: return "Copilot CLI"
    case .codex: return "Codex"
    case .openCode: return "OpenCode"
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
        supportsInSessionRecurrence: true,
        // `/goal <condition>` — read off 2.1.261, where it is a first-class slash command
        // ("Set a goal Claude checks before stopping") that starts a turn immediately and
        // installs a Stop hook the session cannot finish past until the condition holds.
        goalDirective: "/goal")

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
      //
      // `supportsSubAgents` was false for the same reason and flipped the same way: read
      // off 1.0.80's `copilot help commands`, which lists `/fleet` ("enable fleet mode for
      // parallel subagent execution"), `/tasks` ("view and manage tasks (subagents and
      // shell commands)") and `/subagents`, plus `--agent <agent>` on the launch line.
      // That is the fan-out a composite leans on. The same age caveat applies: a
      // composite whose Copilot workers never fan out is a Copilot older than that.
      //
      // `goalDirective` follows `supportsInSessionRecurrence`'s history exactly: set from
      // a `copilot help commands` listing that did not mention the command, then flipped
      // because Copilot has it. That listing is not the authority it looks like — it omits
      // `/loop` and `/every` too, which this row has claimed and relied on for releases.
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: false,
        supportsStructuredOutput: true,
        supportsSubAgents: true,
        supportsMCP: true,
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: true,
        goalDirective: "/goal")

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
      // `/loop` equivalent aren't visible in the CLI surface, so recurrence is provided
      // by graphcode's daemon rather than claimed as an in-session feature.
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: false,
        supportsStructuredOutput: false,
        supportsSubAgents: false,
        supportsMCP: true,
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: false,
        supportsDaemonRecurrence: true,
        // `/goal [<objective>|clear|edit|pause|resume]` — read off 0.153.2, which pursues
        // the objective across turns and reports against it. Same directive name as Claude
        // Code's, so `GoalSpec` composes one prompt shape for both.
        goalDirective: "/goal")

    case .openCode:
      // Spiked against OpenCode 1.18.21 — every entry read off `opencode --help` and its
      // plugin SDK, and every uncertain one left false.
      //
      // `opencode [project] --prompt <text>` opens the TUI already running the prompt,
      // which is graphcode's session model (`opencode run` is the headless shape it
      // deliberately doesn't use). `--auto` is the unattended permission mode, `-m
      // provider/model` picks a model, and `-s <id>` resumes. MCP is first-class
      // (`opencode mcp`). It's a TUI in a PTY, so `zmx send` can type into it.
      //
      // `supportsHooks` is true and is the interesting row: OpenCode has no hook *flags*
      // but a plugin API whose events cover both edges of a turn (`session.status`,
      // `session.idle`), tool calls (`tool.execute.before`) and permission prompts
      // (`permission.asked`). graphcode ships a plugin through `OPENCODE_CONFIG`, which
      // merges over the user's own config rather than replacing it — verified in the
      // source, not assumed (`PresenceHooks.openCodePlugin`).
      //
      // Sub-agents exist inside the TUI (`@agent` mentions) but not as anything a
      // composite could lean on from outside. Recurrence is provided by graphcode's daemon.
      //
      // `goalDirective` is the one row here not read off the CLI: `/goal` is absent from
      // 1.18.29's command strings, and it is set anyway on the maintainer's word that the
      // command exists. The symptom if that is ever wrong is specific — a goal session
      // that opens with `/goal …` echoed as plain text and starts no work — and this
      // comment, not a bisect, is where to look.
      return BackendCapabilities(
        supportsGoalMode: true,
        supportsHooks: true,
        supportsStructuredOutput: false,
        supportsSubAgents: false,
        supportsMCP: true,
        supportsMidSessionInput: true,
        supportsInSessionRecurrence: false,
        supportsDaemonRecurrence: true,
        goalDirective: "/goal")
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
  /// All four, now that Codex and OpenCode have adapters and rows read off their real CLIs.
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
    case .sketch:
      // A bare session — the least demanding type. Every launchable backend hosts it.
      return true
    case .turnBased:
      return true
    case .goalBased:
      return capabilities.supportsGoalMode
    case .timeBased:
      // The cadence lives inside the session, so this needs a backend whose agent can
      // re-trigger its own work. Without that a `/loop …` prompt runs once and stops,
      // which reads as a broken schedule rather than an unsupported one.
      return capabilities.supportsInSessionRecurrence || capabilities.supportsDaemonRecurrence
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
