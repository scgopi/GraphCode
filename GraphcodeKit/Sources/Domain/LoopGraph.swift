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
/// `project` (Phase 4, docs/07-roadmap.md#phase-4--projects) gives every graph a real
/// folder-backed identity — but there is still no `LoopGraphScope` enum (`.global` vs
/// `.project`, see
/// docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope): the
/// global Orchestrator Graph itself is still deferred, so every `LoopGraph` here is
/// unconditionally project-scoped rather than holding an enum with only one case.
public struct LoopGraph: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var project: ProjectRef
  public var nodes: IdentifiedArrayOf<LoopNode>
  public var edges: IdentifiedArrayOf<LoopEdge>

  public init(
    id: UUID = UUID(),
    project: ProjectRef,
    nodes: IdentifiedArrayOf<LoopNode> = [],
    edges: IdentifiedArrayOf<LoopEdge> = []
  ) {
    self.id = id
    self.project = project
    self.nodes = nodes
    self.edges = edges
  }
}
