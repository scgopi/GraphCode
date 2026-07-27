/// The three ways loops talk to each other — see
/// docs/02-graph-of-loops.md#edgekind--the-three-ways-loops-talk-to-each-other.
///
/// All three are now selectable in the canvas's edge drop editor, but only `.handoff`
/// is *executed* by `graphcoded` today: it alone blocks its target until it fires, and
/// it alone is evaluated when a source node resolves. `.message` (live injection into a
/// running peer, needs `MessageBusClient`) and `.spawn` (instantiate rather than
/// unblock, and the one kind allowed to cross graphs) are stored and drawn but inert —
/// see docs/07-roadmap.md#phase-6.
public enum EdgeKind: String, Codable, CaseIterable, Sendable {
  case handoff
  case message
  case spawn

  public var displayName: String {
    switch self {
    case .handoff: return "Handoff"
    case .message: return "Message"
    case .spawn: return "Spawn"
    }
  }

  /// All three are acted on by `graphcoded` now — `.handoff` unblocks, `.message`
  /// delivers into a live session, `.spawn` instantiates.
  public var isExecutable: Bool { true }

  /// Only a `.handoff` gates its target's readiness — a `.message` peer runs
  /// concurrently by definition, and a `.spawn` target is a template that isn't waiting
  /// on anything. Also what cycle traversal follows, since sequencing is the relation a
  /// cycle is made of.
  public var blocksTarget: Bool { self == .handoff }
}
