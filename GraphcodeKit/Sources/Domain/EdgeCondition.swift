/// When an edge is allowed to fire — see docs/02-graph-of-loops.md#loopedge. From
/// Phase 3 on, `graphcoded`'s `GraphStore` evaluates this automatically against the
/// `from` node's resolved `LoopState` (`.succeeded`/`.failed`) — see
/// docs/07-roadmap.md#phase-3--orchestrator-automation. The cycle-guard cases the full
/// taxonomy describes (`.maxIterations`, `.until`) are still deferred: nothing in the
/// current edge/node model can re-fire the same edge or re-create nodes, so a cycle
/// can't actually run away yet — revisit once spawn edges and composites (Phase 6)
/// make that possible.
public enum EdgeCondition: String, Codable, CaseIterable, Sendable {
  case always
  case onSuccess
  case onFailure

  public var displayName: String {
    switch self {
    case .always: return "Always"
    case .onSuccess: return "On success"
    case .onFailure: return "On failure"
    }
  }

  /// Whether an edge with this condition should fire given how its source resolved.
  /// Lives here rather than inline in `GraphStore` so the edge editor can explain the
  /// same rule it enforces.
  public func isSatisfied(sourceSucceeded: Bool) -> Bool {
    switch self {
    case .always: return true
    case .onSuccess: return sourceSucceeded
    case .onFailure: return !sourceSucceeded
    }
  }
}
