/// The three ways loops talk to each other — see
/// docs/02-graph-of-loops.md#edgekind--the-three-ways-loops-talk-to-each-other.
///
/// Phase 3 automates `.handoff` firing in `graphcoded`; `.message` and `.spawn` exist
/// because the edge-kind vocabulary is fixed, not because they're usable yet — live
/// messaging lands in Phase 5, cross-graph spawn in Phase 5 (see
/// docs/07-roadmap.md).
public enum EdgeKind: String, Codable, CaseIterable, Sendable {
  case handoff
  case message
  case spawn
}
