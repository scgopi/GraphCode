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
}
