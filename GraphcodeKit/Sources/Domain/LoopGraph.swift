import Foundation
import IdentifiedCollections

/// The unit `graphcoded`'s `GraphStore` owns and the graph canvas renders — see
/// docs/02-graph-of-loops.md#loopgraph.
///
/// `nodes`/`edges` are `IdentifiedArrayOf` rather than the doc's plain `[LoopNode]`/
/// `[LoopEdge]` pseudocode: same value, but with O(1) by-id lookup/mutation.
/// `IdentifiedCollections` is a small, TCA-independent package, so Domain types using
/// it stays free of any real TCA/SwiftUI coupling.
///
/// Still no `scope` field (`.global` vs `.project` — see
/// docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope): the
/// global Orchestrator Graph itself is deferred past Phase 3 (see
/// docs/07-roadmap.md) even though the daemon that would host it now exists. Every
/// `LoopGraph` here is implicitly project-scoped.
public struct LoopGraph: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var nodes: IdentifiedArrayOf<LoopNode>
  public var edges: IdentifiedArrayOf<LoopEdge>

  public init(
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
