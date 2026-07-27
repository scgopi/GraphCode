/// Runtime state of a `LoopNode`. From Phase 3 on this is genuinely owned by the
/// orchestrator (`graphcoded`'s `GraphStore`), not the app — see
/// docs/02-graph-of-loops.md.
///
/// `Idle → Running → { AwaitingInput, Blocked } → Running → { Succeeded, Failed, Stalled }`
public enum LoopState: Codable, Equatable, Sendable {
  case idle
  case running
  case awaitingInput
  case blocked
  case succeeded
  case failed
  case stalled
  /// A human stopped it from the orchestrator monitor
  /// (docs/05-orchestrator.md#monitoring-surface).
  ///
  /// Distinct from `.failed` on purpose: the work didn't go wrong, someone decided it
  /// shouldn't continue. Collapsing the two would file every deliberate stop into the
  /// monitor's "Failed" queue, which is precisely the noise the rollup exists to avoid.
  case stopped
}
