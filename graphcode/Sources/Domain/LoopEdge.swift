import Foundation

/// A relationship between two loops — see docs/02-graph-of-loops.md#loopedge.
///
/// `fired` is a Phase 2 addition, not part of the documented long-term shape: with no
/// orchestrator yet to own edge-firing as runtime state, it's stored directly on the
/// edge, the same pragmatic call Phase 1 made embedding `LoopState` directly on
/// `LoopNode`. `payloadNote` is similarly a placeholder for the richer, inspectable
/// `payloadTransform` the architecture doc describes — a plain description for now,
/// since nothing executes it until an orchestrator exists to apply it.
struct LoopEdge: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let from: UUID
  let to: UUID
  var kind: EdgeKind
  var condition: EdgeCondition
  var payloadNote: String?
  var fired: Bool

  init(
    id: UUID = UUID(),
    from: UUID,
    to: UUID,
    kind: EdgeKind = .handoff,
    condition: EdgeCondition = .always,
    payloadNote: String? = nil,
    fired: Bool = false
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.kind = kind
    self.condition = condition
    self.payloadNote = payloadNote
    self.fired = fired
  }
}
