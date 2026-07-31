import Foundation

/// What a goal-based loop is handed instead of a check: the stop condition — see
/// docs/01-loop-taxonomy.md#goal-based--you-hand-off-the-stop-condition.
///
/// `summary` is the human statement of done; `predicate` is the optional machine
/// version. docs/08-quality-and-token-budgets.md wants "a goal-based node without a real
/// stop condition" to be a modelling error rather than a best practice, so `summary` is
/// non-optional and the creation form refuses to submit an empty one — but `predicate`
/// stays optional, because plenty of real goals ("the design doc reads clearly") have no
/// honest shell equivalent, and inventing one would be worse than admitting it.
///
/// With a predicate, `graphcoded` polls it and resolves the node the moment it holds;
/// without one, the node resolves the same way every other loop does — when its session
/// exits (see `AppFeature`'s `.primarySurfaceExited`).
public struct GoalSpec: Codable, Equatable, Sendable {
  /// What "done" means, in the human's words. Also what gets written into the session's
  /// opening prompt.
  public var summary: String
  /// A shell command whose exit status answers "is the goal met yet?" — 0 means yes.
  /// Deliberately a command rather than a model call: docs/08's "use scripts for
  /// deterministic work" applies most sharply to something re-run on every poll.
  public var predicate: String?
  /// How often the predicate runs. Defaults to a minute — docs/08 asks for conservative
  /// defaults over tight ones, and a stop condition that's expensive to evaluate is
  /// exactly the kind of thing that shouldn't be hammered.
  public var pollIntervalSeconds: Double
  /// How long the loop may run before `graphcoded` calls it `.stalled`
  /// (docs/05-orchestrator.md#responsibilities). `nil` means it runs until it resolves,
  /// which is the right default for goals with no predictable duration.
  public var stallAfterSeconds: Double?
  /// A shell command whose stdout's last line is a *number* measuring how the work is
  /// going — distinct from `predicate`, which answers done/not-done. Kept separate
  /// because the idiomatic predicates are quiet (`git diff --quiet`,
  /// `test $(…) -eq 0`), so overloading their stdout would collide with exactly the
  /// commands people reach for first.
  ///
  /// Sampled once per cycle pass, at re-entry, alongside the guard's `until` predicate —
  /// not on every poll, so an expensive metric (a test-suite run) costs one run per
  /// pass, per docs/08's conservative-polling stance.
  public var metricCommand: String?
  /// Which way `metricCommand`'s number should move. Defaults to `.maximize`.
  public var metricDirection: MetricDirection

  public init(
    summary: String,
    predicate: String? = nil,
    pollIntervalSeconds: Double = 60,
    stallAfterSeconds: Double? = nil,
    metricCommand: String? = nil,
    metricDirection: MetricDirection = .maximize
  ) {
    self.summary = summary
    self.predicate = predicate
    self.pollIntervalSeconds = pollIntervalSeconds
    self.stallAfterSeconds = stallAfterSeconds
    self.metricCommand = metricCommand
    self.metricDirection = metricDirection
  }

  /// Non-empty predicate or nil — an all-whitespace field is a human leaving it blank,
  /// not a command that always succeeds.
  public var effectivePredicate: String? {
    guard let predicate else { return nil }
    let trimmed = predicate.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Non-empty metric command or nil, by the same rule as `effectivePredicate`.
  public var effectiveMetricCommand: String? {
    guard let metricCommand else { return nil }
    let trimmed = metricCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The opening prompt for the node's session. States the goal, and — when there's a
  /// predicate or a metric — tells the session the same things the daemon is watching,
  /// so the two aren't working to different definitions of done, or of better.
  ///
  /// The metric sentence is the half that makes it a *method* rather than a score: the
  /// loop is told how its performance is measured and to measure itself while working,
  /// the way an autonomous improvement loop is handed its own fitness function. The
  /// orchestrator still samples the same command once per pass, so the recorded numbers
  /// come from the measurement, never from the loop's self-report.
  public var sessionPrompt: String {
    var parts = ["Work toward this goal until it is met: \(summary)"]
    if let predicate = effectivePredicate {
      parts.append("The goal counts as met when this command exits 0: \(predicate)")
    }
    if let metric = effectiveMetricCommand {
      // Kept terse on purpose: the launch prompt is typed into a terminal and shares a
      // hard byte budget with everything else on the line (`SessionBriefing`) — every
      // word here is space a long goal or predicate can no longer use.
      parts.append(
        "Measure your performance with this command (\(metricDirection.displayName)): "
          + "\(metric) — run it as you work; the orchestrator samples it each pass.")
    }
    return parts.joined(separator: " ")
  }

  private enum CodingKeys: String, CodingKey {
    case summary, predicate, pollIntervalSeconds, stallAfterSeconds
    case metricCommand, metricDirection
  }

  /// Hand-written for the same reason `LoopEdge`'s is: a field added after a graph was
  /// saved must decode to its default rather than failing the whole project's load.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
    predicate = try container.decodeIfPresent(String.self, forKey: .predicate)
    pollIntervalSeconds =
      try container.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 60
    stallAfterSeconds = try container.decodeIfPresent(Double.self, forKey: .stallAfterSeconds)
    metricCommand = try container.decodeIfPresent(String.self, forKey: .metricCommand)
    metricDirection =
      try container.decodeIfPresent(MetricDirection.self, forKey: .metricDirection) ?? .maximize
  }
}
