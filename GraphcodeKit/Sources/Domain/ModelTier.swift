/// Which model tier a loop's session runs on — docs/08-quality-and-token-budgets.md's
/// "choose the right primitive and model for the job", and
/// docs/05-orchestrator.md#responsibilities item 7.
///
/// The tiers are deliberately named by *role* rather than by model: the orchestrator's
/// job is deciding that bulk triage is cheap work and a judgment call isn't, which is a
/// stable decision. Which model is currently cheapest is not, and baking a specific one
/// into every persisted node would make graph files go stale every time the model lineup
/// changes.
public enum ModelTier: String, Codable, CaseIterable, Sendable {
  /// Routine, high-volume work — triage, classification, per-item fan-out.
  case fast
  /// The default. No opinion either way.
  case standard
  /// Judgment calls: checks, judges, and goal stop-condition evaluation. The tier
  /// docs/08 says to reserve rather than spend.
  case capable

  public var displayName: String {
    switch self {
    case .fast: return "Fast"
    case .standard: return "Standard"
    case .capable: return "Capable"
    }
  }

  /// The `--model` argument for a backend that takes one.
  ///
  /// Aliases, not pinned model ids, for the same reason the tiers are named by role:
  /// the alias keeps resolving to the current model in that class, where a pinned id
  /// would rot. `.standard` returns nil — passing no flag lets the backend's own default
  /// apply, which is different from insisting on whatever we think its default is.
  public var modelAlias: String? {
    switch self {
    case .fast: return "haiku"
    case .standard: return nil
    case .capable: return "opus"
    }
  }
}

extension ModelTier {
  /// The tier a session actually runs at, given what the human pinned for the loop and
  /// whether they've asked graphcode to route models on their behalf at all.
  ///
  /// The pin always wins — someone who picked a tier for a loop meant it, and the setting
  /// is about what happens when *nobody* picked.
  ///
  /// Unpinned and auto-selection off yields `.standard`, which emits no `--model` for any
  /// backend, so the CLI's own configured default applies. That is the honest answer to
  /// "which model should this use" when nobody has said: whatever `claude`, `copilot` or
  /// `codex` is already set up to use. graphcode routing by loop type was a reasonable
  /// guess (docs/08's "choose the right model for the job") and a wrong one to make
  /// silently — it quietly overrode the model people had deliberately configured in their
  /// own CLI, which is what issue #10 is about. Off is the default for that reason.
  public static func resolved(
    pinned: ModelTier?, for loopType: LoopType, autoSelecting: Bool
  ) -> ModelTier {
    if let pinned { return pinned }
    return autoSelecting ? loopType.defaultModelTier : .standard
  }
}

extension LoopType {
  /// The tier the orchestrator picks when a human hasn't **and** has turned model
  /// auto-selection on. docs/08 is explicit that this is a *scheduling* decision —
  /// something the orchestrator makes across a graph — not something each node decides
  /// for itself.
  ///
  /// Turn-based is `.capable` because its entire job is judging whether work is good
  /// enough, which is exactly the judgment call docs/08 says to reserve the top tier
  /// for. Time-based polling is the routine end of the scale.
  ///
  /// Opt-in rather than the standing behaviour — see `ModelTier.resolved`.
  public var defaultModelTier: ModelTier {
    switch self {
    case .sketch: return .standard
    case .turnBased: return .capable
    case .goalBased: return .standard
    case .timeBased: return .fast
    case .composite: return .standard
    }
  }
}
