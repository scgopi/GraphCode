/// Runtime state of a `LoopNode`, owned by the orchestrator rather than the node
/// itself — see docs/02-graph-of-loops.md.
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
