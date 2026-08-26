/// A shell command graphcode runs to answer a yes/no question about the world — exit 0
/// is yes.
///
/// Three separate things in the design turn out to need exactly this: a goal-based
/// node's stop condition (docs/05-orchestrator.md#responsibilities), a cyclic edge's
/// `until` guard (docs/02-graph-of-loops.md), and docs/08's "use scripts for
/// deterministic work — a script is cheaper than reasoning through the steps every
/// time". One evaluator serves all three rather than each growing its own subprocess
/// handling and its own quoting mistakes.
public struct ShellPredicate: Equatable, Sendable {
  public let command: String
  /// Where to run it. A node's worktree when it has one, so a predicate like
  /// `git diff --quiet` asks about the right tree.
  public let workingDirectory: String?

  public init(command: String, workingDirectory: String? = nil) {
    self.command = command
    self.workingDirectory = workingDirectory
  }
}

/// A predicate run that kept its evidence: did it hold, and what the command printed on
/// the way to that answer. The exit status alone was enough for resolving a goal, but a
/// *failing* stop condition has one more job — telling the session *why* it isn't done
/// yet — and by the time anyone wants the output, the run that produced it is gone.
public struct PredicateOutcome: Equatable, Sendable {
  public let passed: Bool
  /// The last stretch of combined stdout+stderr, bounded at the evaluator so a chatty
  /// test suite can't turn a nudge into a transcript. Empty when the command printed
  /// nothing worth relaying.
  public let outputTail: String

  public init(passed: Bool, outputTail: String = "") {
    self.passed = passed
    self.outputTail = outputTail
  }
}
