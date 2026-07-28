import Foundation

/// How to actually invoke a backend's CLI — the argv graphcode builds for a node's
/// session, in the one place both callers can reach.
///
/// There are exactly two: `ZmxSessionLauncher`, which starts a detached session from the
/// daemon, and `GhosttyTerminalView`, which attaches the app's terminal to one. Before
/// this they each hardcoded `claude`, which meant a node whose backend said Copilot
/// opened a Claude Code session — the picker and the process disagreeing, silently. A
/// single source of truth is the fix.
extension CLISessionBackendKind {
  /// The binary a human would type. `nil` for a backend graphcode can't launch, which is
  /// also why `canHost` refuses everything for it.
  public var executableName: String? {
    switch self {
    case .claudeCode: return "claude"
    case .copilotCLI: return "copilot"
    case .codex: return nil
    }
  }

  /// The model each tier maps to for this backend.
  ///
  /// Deliberately per-backend rather than one shared alias list: Claude Code takes short
  /// aliases that keep resolving to the current model in a class, whereas Copilot's
  /// `--model` takes explicit versioned ids from a fixed set (read off `copilot --help`
  /// at 0.0.410). Pointing the same string at both would silently fail on one of them.
  ///
  /// `.standard` returns nil everywhere — passing no flag lets the backend's own default
  /// apply, which is different from asserting what we think it is.
  public func modelArguments(for tier: ModelTier) -> [String] {
    switch self {
    case .claudeCode:
      return tier.modelAlias.map { ["--model", $0] } ?? []
    case .copilotCLI:
      switch tier {
      case .fast: return ["--model", "claude-haiku-4.5"]
      case .standard: return []
      case .capable: return ["--model", "claude-opus-4.6"]
      }
    case .codex:
      return []
    }
  }

  /// Everything after the executable, for a session that should open running `prompt`
  /// (or bare, when there isn't one), optionally carrying a `briefing` about the graph it
  /// belongs to (`SessionBriefing`).
  ///
  /// The shapes genuinely differ: `claude` takes its opening prompt as a positional
  /// argument, while `copilot` takes it as the value of `--interactive`. Note this is
  /// `--interactive`, not `-p/--prompt` — the latter exits when the work finishes, and a
  /// loop nobody can attach to and steer is the model graphcode deliberately moved away
  /// from.
  ///
  /// The briefing is delivered differently for the same reason, and the difference is not
  /// cosmetic. `claude` takes `--append-system-prompt-file <path>`, which adds the file's
  /// contents to its system prompt and leaves the human's prompt as the only thing in the
  /// conversation. `copilot` has no equivalent — its custom instructions come from
  /// `AGENTS.md` files it discovers on disk (hence `--no-custom-instructions` to switch
  /// that off), which graphcode has no business writing into someone's repository. So
  /// there the briefing arrives through the environment instead —
  /// `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, set by `ZmxSessionLauncher` — which is Copilot's
  /// own supported channel for custom instructions and needs nothing in the prompt.
  ///
  /// Neither carries the prose on the command line. See `SessionBriefing` for why that is
  /// load-bearing rather than tidy: the launch command is typed into a terminal, and a
  /// briefing-sized argument overruns the tty's canonical input buffer.
  public func launchArguments(
    prompt: String?, tier: ModelTier, briefingFile: URL? = nil,
    settings: GraphcodeSettings = GraphcodeSettings()
  ) -> [String] {
    let model = modelArguments(for: tier) + permissionArguments(settings)
    guard let prompt, !prompt.isEmpty else { return model }
    switch self {
    case .claudeCode:
      let system = briefingFile.map { ["--append-system-prompt-file", $0.path] } ?? []
      return model + system + [prompt]
    case .copilotCLI:
      // Nothing about the briefing rides in the prompt. Copilot reads it from the
      // directory `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` points at, which
      // `ZmxSessionLauncher` sets on the session's environment — so the human's request
      // is the only thing in the conversation, exactly as it is for Claude Code.
      return model + ["--interactive", prompt]
    case .codex:
      return []
    }
  }

  /// How much a session may do without stopping to ask.
  ///
  /// A loop is unattended by construction — the daemon starts it whether or not a window
  /// is open, and nobody is watching the pane when it asks whether it may edit a file. A
  /// backend left on its interactive default sits at that prompt indefinitely while the
  /// graph reports it as `running`, which is the same "looks alive, does nothing" failure
  /// as the trust-this-folder dialog.
  ///
  /// The defaults are deliberately *not* the most permissive setting either backend
  /// offers, though a human can choose those in Settings. Claude Code's
  /// `auto` keeps its guardrails while approving the ordinary work of a coding session;
  /// `bypassPermissions` (and `--dangerously-skip-permissions`) removes the checks
  /// entirely. Copilot's nearest equivalent is `--allow-all-tools` — tools run without
  /// confirmation — rather than `--allow-all`/`--yolo`, which additionally disable path
  /// verification and URL checks, letting a session reach outside the project it was
  /// started in. Auto-approving work *in the folder the loop was pointed at* is the
  /// bargain a loop implies; reaching past it is not.
  func permissionArguments(_ settings: GraphcodeSettings) -> [String] {
    switch self {
    case .claudeCode: return settings.claudePermissionMode.arguments
    case .copilotCLI: return settings.copilotPermissions.arguments
    case .codex: return []
    }
  }
}
