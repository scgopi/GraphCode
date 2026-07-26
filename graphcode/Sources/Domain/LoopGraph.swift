import Foundation
import IdentifiedCollections

/// The unit shown on the graph canvas — see docs/02-graph-of-loops.md#loopgraph.
///
/// `nodes`/`edges` are `IdentifiedArrayOf` rather than the doc's plain `[LoopNode]`/
/// `[LoopEdge]` pseudocode: same value, but with O(1) by-id lookup/mutation, which
/// `GraphCanvasFeature` needs constantly. `IdentifiedCollections` is a small,
/// TCA-independent package (not `ComposableArchitecture`/SwiftUI), so this doesn't
/// compromise Domain's "no TCA/SwiftUI dependency" rule.
///
/// Phase 2 scope: no `scope` field yet (`.global` vs `.project` — see
/// docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope) — the
/// global Orchestrator Graph is a Phase 3 concept, once `graphcoded` exists to host it.
/// Every `LoopGraph` in this app is implicitly project-scoped until then.
struct LoopGraph: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  var title: String
  var nodes: IdentifiedArrayOf<LoopNode>
  var edges: IdentifiedArrayOf<LoopEdge>

  init(
    id: UUID = UUID(),
    title: String,
    nodes: IdentifiedArrayOf<LoopNode> = [],
    edges: IdentifiedArrayOf<LoopEdge> = []
  ) {
    self.id = id
    self.title = title
    self.nodes = nodes
    self.edges = edges
  }
}
