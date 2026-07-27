import Foundation

/// A relationship between two loops — see docs/02-graph-of-loops.md#loopedge.
///
/// `fired` is owned by `graphcoded`'s `GraphStore` from Phase 3 on (still stored
/// directly on the edge rather than tracked separately — same pragmatic call Phase 1
/// made embedding `LoopState` directly on `LoopNode`).
public struct LoopEdge: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let from: UUID
  public let to: UUID
  public var kind: EdgeKind
  public var condition: EdgeCondition
  public var payloadTransform: PayloadTransform
  public var cycleGuard: CycleGuard?
  /// Set only on a cross-graph `.spawn` — see `EdgeSpec.spawnTargetProjectPath`.
  public var spawnTargetProjectPath: String?
  /// How many times this edge has fired. A plain edge only ever reaches 1; a guarded
  /// cyclic edge counts up, and that count is what `CycleGuard.maxIterations` bounds.
  public var fireCount: Int

  /// Kept as the name every call site and the canvas already use. Now derived rather
  /// than stored, so there's no second source of truth to drift from `fireCount`.
  public var fired: Bool { fireCount > 0 }

  public init(
    id: UUID = UUID(),
    from: UUID,
    to: UUID,
    kind: EdgeKind = .handoff,
    condition: EdgeCondition = .always,
    payloadTransform: PayloadTransform = .none,
    cycleGuard: CycleGuard? = nil,
    spawnTargetProjectPath: String? = nil,
    fireCount: Int = 0
  ) {
    self.id = id
    self.from = from
    self.to = to
    self.kind = kind
    self.condition = condition
    self.payloadTransform = payloadTransform
    self.cycleGuard = cycleGuard
    self.spawnTargetProjectPath = spawnTargetProjectPath
    self.fireCount = fireCount
  }

  public init(id: UUID = UUID(), from: UUID, to: UUID, spec: EdgeSpec, fireCount: Int = 0) {
    self.init(
      id: id, from: from, to: to, kind: spec.kind, condition: spec.condition,
      payloadTransform: spec.payloadTransform, cycleGuard: spec.cycleGuard,
      spawnTargetProjectPath: spec.spawnTargetProjectPath, fireCount: fireCount)
  }

  public var spec: EdgeSpec {
    EdgeSpec(
      kind: kind, condition: condition, payloadTransform: payloadTransform,
      cycleGuard: cycleGuard, spawnTargetProjectPath: spawnTargetProjectPath)
  }

  /// Whether this edge may fire again on count alone. An unguarded edge fires exactly
  /// once — the behaviour every edge had before cycle guards existed.
  public var mayFireAgain: Bool {
    guard let cycleGuard else { return fireCount == 0 }
    return cycleGuard.allowsFiring(afterFireCount: fireCount)
  }

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case id, from, to, kind, condition, payloadTransform, cycleGuard
    case spawnTargetProjectPath, fireCount
    /// Pre-`PayloadTransform` edges stored a plain description here. Still read (never
    /// written) so a graph persisted before the edge editor existed keeps decoding
    /// instead of silently dropping the whole project's saved loops.
    case payloadNote
    /// Pre-`fireCount` edges stored a one-way boolean. Read-only, same reason.
    case fired
  }

  /// Hand-written rather than synthesized specifically so a field added after a graph
  /// was last saved decodes to its default instead of failing the whole `LoopGraph` —
  /// `ProjectPersistence.loadGraph` turns a decode error into "no saved graph", which
  /// would read to a user as their project having been wiped.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    from = try container.decode(UUID.self, forKey: .from)
    to = try container.decode(UUID.self, forKey: .to)
    kind = try container.decodeIfPresent(EdgeKind.self, forKey: .kind) ?? .handoff
    condition = try container.decodeIfPresent(EdgeCondition.self, forKey: .condition) ?? .always
    cycleGuard = try container.decodeIfPresent(CycleGuard.self, forKey: .cycleGuard)
    spawnTargetProjectPath = try container.decodeIfPresent(
      String.self, forKey: .spawnTargetProjectPath)

    if let count = try container.decodeIfPresent(Int.self, forKey: .fireCount) {
      fireCount = count
    } else {
      // A legacy edge could only ever have fired once, so its boolean maps exactly.
      fireCount = (try container.decodeIfPresent(Bool.self, forKey: .fired) ?? false) ? 1 : 0
    }

    if let transform = try container.decodeIfPresent(
      PayloadTransform.self, forKey: .payloadTransform)
    {
      payloadTransform = transform
    } else if let note = try container.decodeIfPresent(String.self, forKey: .payloadNote) {
      payloadTransform = .template(note)
    } else {
      payloadTransform = .none
    }
  }

  /// Explicit because `CodingKeys` carries a read-only legacy key the synthesized
  /// encoder has no property to write. Deliberately never emits `payloadNote`: reading
  /// the old shape is a migration, writing it would be keeping two sources of truth.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(from, forKey: .from)
    try container.encode(to, forKey: .to)
    try container.encode(kind, forKey: .kind)
    try container.encode(condition, forKey: .condition)
    try container.encode(payloadTransform, forKey: .payloadTransform)
    try container.encodeIfPresent(cycleGuard, forKey: .cycleGuard)
    try container.encodeIfPresent(spawnTargetProjectPath, forKey: .spawnTargetProjectPath)
    try container.encode(fireCount, forKey: .fireCount)
  }
}
