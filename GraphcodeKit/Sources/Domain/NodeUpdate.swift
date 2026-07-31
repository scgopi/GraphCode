import Foundation

/// A partial edit to a live loop's configuration — what `GraphCommand.updateNode`
/// carries. Bundled the way `EdgeSpec` is, so a later field is a change to this struct
/// rather than to the wire protocol's shape.
///
/// Every field is optional: `nil` means "leave it alone". Where "set it to nothing" is
/// meaningful, an empty string (or a non-positive number) is the clear signal — the same
/// convention `GoalSpec.effectivePredicate` already applies to whitespace.
///
/// Deliberately *not* representable here: `loopType` and `backend`. Changing either
/// makes a different loop, and delete-plus-recreate is the honest spelling of that.
/// `worktreeBinding` is likewise absent — a live session's working directory can't
/// follow it, and a binding that disagrees with the running session would make every
/// predicate measure the wrong tree.
public struct NodeUpdate: Codable, Equatable, Sendable {
  /// `.goalBased`: new statement of done. Empty is refused, not applied — a goal with
  /// no summary describes nothing (`NodeDraft.isValid`'s rule, held on update too).
  public var goalSummary: String?
  /// `.goalBased`: new stop-condition command. Empty string clears it.
  public var goalPredicate: String?
  public var pollIntervalSeconds: Double?
  /// Non-positive clears the stall bound.
  public var stallAfterSeconds: Double?
  /// `.goalBased`: new metric command (`GoalSpec.metricCommand`). Empty string clears.
  public var metricCommand: String?
  public var metricDirection: MetricDirection?
  /// `.timeBased`: new opening prompt. Reaches a live session only as a nudge; the
  /// session that already ran its old prompt keeps its cadence until relaunched.
  public var triggerPrompt: String?
  /// `.turnBased`: new per-turn criterion.
  public var checkDescription: String?
  /// Takes effect at the session's next launch — the daemon never restarts a live
  /// session to apply it.
  public var modelTier: ModelTier?
  /// The loop this update came from, when the CLI could attribute it (`ZMX_SESSION`,
  /// the same mechanism as `NodeDraft.createdBy`). `nil` from a human's shell or the
  /// app. Provenance, not authentication — it makes the honest path say who asked.
  public var updatedBy: UUID?

  public init(
    goalSummary: String? = nil,
    goalPredicate: String? = nil,
    pollIntervalSeconds: Double? = nil,
    stallAfterSeconds: Double? = nil,
    metricCommand: String? = nil,
    metricDirection: MetricDirection? = nil,
    triggerPrompt: String? = nil,
    checkDescription: String? = nil,
    modelTier: ModelTier? = nil,
    updatedBy: UUID? = nil
  ) {
    self.goalSummary = goalSummary
    self.goalPredicate = goalPredicate
    self.pollIntervalSeconds = pollIntervalSeconds
    self.stallAfterSeconds = stallAfterSeconds
    self.metricCommand = metricCommand
    self.metricDirection = metricDirection
    self.triggerPrompt = triggerPrompt
    self.checkDescription = checkDescription
    self.modelTier = modelTier
    self.updatedBy = updatedBy
  }

  /// An update that changes nothing is refused rather than quietly applied.
  public var isEmpty: Bool {
    goalSummary == nil && goalPredicate == nil && pollIntervalSeconds == nil
      && stallAfterSeconds == nil && metricCommand == nil && metricDirection == nil
      && triggerPrompt == nil && checkDescription == nil && modelTier == nil
  }

  /// Whether this update touches what decides the loop is finished. The one edit a loop
  /// may not make to *itself*: the verifier stays outside the verified, for the same
  /// reason maker and critic are separate sessions.
  public var touchesStopCondition: Bool {
    goalPredicate != nil
  }
}
