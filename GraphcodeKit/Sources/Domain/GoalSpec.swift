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
  /// How many tokens this loop may spend before the orchestrator ends it —
  /// docs/08-quality-and-token-budgets.md's budget, finally enforced rather than
  /// reviewed after the fact. `nil` means unbounded, which stays the default: a budget
  /// is a bound the author chose, never one invented.
  ///
  /// Counted the way the backend's API meters, not the way a turn feels: input,
  /// output, cache creation *and cache reads* all count, because each is billed usage
  /// (`PresenceHooks.usageScript` sums the transcript's four token fields). That makes
  /// a Claude Code budget a per-turn cost — every turn re-meters the whole context as
  /// cache reads — so a bound sized from turn counts is spent in minutes. The help
  /// text says this because "(input + output)" read as hours and was not.
  ///
  /// Enforcement shares `UsageSample`'s honesty rule: usage is *reported* by the
  /// backend's hooks, never estimated, so a loop whose backend reports nothing can
  /// never blow this bound. The budget is only as real as the reporting — the poller
  /// acts on what was reported, and stays silent about what wasn't.
  public var tokenBudget: Int?
  /// When true, the poller skips re-running the predicate while the session is busy
  /// and the working tree is unchanged (same `HEAD`, same dirty files) since the last
  /// failing run. An idle session on that unchanged tree gets one more predicate run
  /// and one more failure relay — a goal loop is the only writer of its own tree and
  /// only writes once woken, so gating the wake on a tree change would strand it —
  /// after which polls stay quiet until the tree moves again. Off by default with
  /// reason: plenty of predicates watch things *outside* the tree — a CI run, a
  /// deployed endpoint — and the skip buys them least. Opt in when the predicate is a
  /// function of the tree (a test suite, a lint) and expensive enough that docs/08's
  /// conservative-polling stance applies.
  public var skipsUnchangedWorkspace: Bool

  public init(
    summary: String,
    predicate: String? = nil,
    pollIntervalSeconds: Double = 60,
    stallAfterSeconds: Double? = nil,
    metricCommand: String? = nil,
    metricDirection: MetricDirection = .maximize,
    tokenBudget: Int? = nil,
    skipsUnchangedWorkspace: Bool = false
  ) {
    self.summary = summary
    self.predicate = predicate
    self.pollIntervalSeconds = pollIntervalSeconds
    self.stallAfterSeconds = stallAfterSeconds
    self.metricCommand = metricCommand
    self.metricDirection = metricDirection
    self.tokenBudget = tokenBudget
    self.skipsUnchangedWorkspace = skipsUnchangedWorkspace
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
    if let budget = tokenBudget, budget > 0 {
      // Told to the session for the same reason the metric is: a loop that doesn't know
      // its budget can't pace itself toward it — it can only be surprised by it. The
      // counting is stated because a session metering its own spend from the API would
      // otherwise pace against a number the orchestrator doesn't use.
      parts.append(
        "Token budget: \(budget), counted over every token the API meters (cache reads "
          + "included) — the orchestrator ends this loop if it spends more.")
    }
    return parts.joined(separator: " ")
  }

  private enum CodingKeys: String, CodingKey {
    case summary, predicate, pollIntervalSeconds, stallAfterSeconds
    case metricCommand, metricDirection, tokenBudget, skipsUnchangedWorkspace
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
    tokenBudget = try container.decodeIfPresent(Int.self, forKey: .tokenBudget)
    skipsUnchangedWorkspace =
      try container.decodeIfPresent(Bool.self, forKey: .skipsUnchangedWorkspace) ?? false
  }
}
