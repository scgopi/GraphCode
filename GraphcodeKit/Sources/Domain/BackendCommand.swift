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
  /// (or bare, when there isn't one).
  ///
  /// The shapes genuinely differ: `claude` takes its opening prompt as a positional
  /// argument, while `copilot` takes it as the value of `--interactive`. Note this is
  /// `--interactive`, not `-p/--prompt` — the latter exits when the work finishes, and a
  /// loop nobody can attach to and steer is the model graphcode deliberately moved away
  /// from.
  public func launchArguments(prompt: String?, tier: ModelTier) -> [String] {
    let model = modelArguments(for: tier)
    guard let prompt, !prompt.isEmpty else { return model }
    switch self {
    case .claudeCode: return model + [prompt]
    case .copilotCLI: return model + ["--interactive", prompt]
    case .codex: return []
    }
  }
}
