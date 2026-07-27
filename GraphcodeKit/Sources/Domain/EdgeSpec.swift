/// Everything a human picks in the canvas's edge drop editor
/// (docs/06-ux-terminals.md#creating-edges), bundled so `GraphCommand.createEdge`
/// carries one value instead of four loose parameters — and so adding a field later is
/// a change to this struct rather than to the wire protocol's shape.
///
/// The defaults are exactly what dragging an edge used to produce before the editor
/// existed (a plain `.handoff` that always fires), so an un-customized edge behaves the
/// way every edge did through Phase 4.
public struct EdgeSpec: Codable, Equatable, Sendable {
  public var kind: EdgeKind
  public var condition: EdgeCondition
  public var payloadTransform: PayloadTransform
  /// Set only on an edge meant to close a loop back to an ancestor. Its presence is what
  /// lets the edge fire more than once — see `CycleGuard`.
  public var cycleGuard: CycleGuard?
  /// For a `.spawn` edge that targets a node in a *different* graph — the one edge kind
  /// allowed to cross (docs/02-graph-of-loops.md#edgekind). `nil` means the spawn stays
  /// inside its own graph, which is what every project-scoped spawn does.
  ///
  /// This is how the global Orchestrator Graph dispatches into a project: a global node
  /// classifies what it found, and its `.spawn` edge instantiates a loop over in the
  /// project that work belongs to.
  public var spawnTargetProjectPath: String?

  public init(
    kind: EdgeKind = .handoff,
    condition: EdgeCondition = .always,
    payloadTransform: PayloadTransform = .none,
    cycleGuard: CycleGuard? = nil,
    spawnTargetProjectPath: String? = nil
  ) {
    self.kind = kind
    self.condition = condition
    self.payloadTransform = payloadTransform
    self.cycleGuard = cycleGuard
    self.spawnTargetProjectPath = spawnTargetProjectPath
  }
}
