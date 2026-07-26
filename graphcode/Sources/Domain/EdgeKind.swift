/// The three ways loops talk to each other — see
/// docs/02-graph-of-loops.md#edgekind--the-three-ways-loops-talk-to-each-other.
///
/// Phase 2 only wires up `.handoff` (the manual "drag an edge, mark it fired" model);
/// `.message` and `.spawn` exist because the edge-kind vocabulary is fixed, not because
/// they're usable yet — live messaging lands in Phase 5, cross-graph spawn in Phase 3/5
/// (see docs/07-roadmap.md).
enum EdgeKind: String, Codable, CaseIterable, Sendable {
  case handoff
  case message
  case spawn
}
