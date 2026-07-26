import Foundation

/// A relationship between two loops — see docs/02-graph-of-loops.md#loopedge.
///
/// `fired` is owned by `graphcoded`'s `GraphStore` from Phase 3 on (still stored
/// directly on the edge rather than tracked separately — same pragmatic call Phase 1
/// made embedding `LoopState` directly on `LoopNode`). `payloadNote` is a placeholder
/// for the richer, inspectable `payloadTransform` the architecture doc describes — a
/// plain description for now, since nothing executes it.
public struct LoopEdge: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let from: UUID
  public let to: UUID
  public var kind: EdgeKind
  public var condition: EdgeCondition
  public var payloadNote: String?
  public var fired: Bool

  public init(
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
