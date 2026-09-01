import ArtifactoryKit
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
/// `scope` distinguishes a project's graph from the one global Orchestrator Graph
/// (docs/02-graph-of-loops.md#the-orchestrator-graph--global-vs-project-scope). `project`
/// remains available for both — the global graph reports a reserved
/// `graphcode://global` ref — so persistence, registry routing, and every existing
/// `graph.project.path` call site work without knowing the difference.
public struct LoopGraph: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var scope: LoopGraphScope
  public var nodes: IdentifiedArrayOf<LoopNode>
  public var edges: IdentifiedArrayOf<LoopEdge>
  /// The project's Artifactory — every post any loop has dropped onto the shared board,
  /// oldest first, capped at `Artifactory.maxPosts`. Kept on the graph rather than in a
  /// side store so it inherits for free everything graph state already has: one
  /// writer (the daemon), atomic persistence beside the graph file, a snapshot in
  /// every `.graphChanged` (which is how the CLI reads it — no second read path), and
  /// the global graph at `graphcode://global` becoming a cross-project board without
  /// a line of extra code. Empty for anyone who never touches the board; graphs saved
  /// before the field existed decode with it empty.
  public var artifactory: [ArtifactoryPost] = []

  public var project: ProjectRef {
    get { scope.projectRef }
    set { scope = LoopGraphScope(projectPath: newValue.path, name: newValue.name) }
  }

  public var isGlobal: Bool { scope.isGlobal }

  public init(
    id: UUID = UUID(),
    scope: LoopGraphScope,
    nodes: IdentifiedArrayOf<LoopNode> = [],
    edges: IdentifiedArrayOf<LoopEdge> = []
  ) {
    self.id = id
    self.scope = scope
    self.nodes = nodes
    self.edges = edges
  }

  public init(
    id: UUID = UUID(),
    project: ProjectRef,
    nodes: IdentifiedArrayOf<LoopNode> = [],
    edges: IdentifiedArrayOf<LoopEdge> = []
  ) {
    self.init(
      id: id,
      scope: LoopGraphScope(projectPath: project.path, name: project.name),
      nodes: nodes,
      edges: edges)
  }

  /// Whether this graph holds `nodeID` anywhere beneath it, composites' contents
  /// included.
  ///
  /// Node ids are unique across the whole tree — that is what makes them `zmx` session
  /// names — so a caller naming one has no reason to know, or say, how deep it sits.
  /// Addressing a nested composite would otherwise mean spelling out the chain of
  /// parents to reach it.
  public func containsAtAnyDepth(_ nodeID: UUID) -> Bool {
    nodes.contains { $0.id == nodeID || ($0.subGraph?.containsAtAnyDepth(nodeID) ?? false) }
  }

  /// Every node in this graph and, recursively, inside any composite's sub-graph.
  ///
  /// The enumeration counterpart to `containsAtAnyDepth`, for teardown: a piloted
  /// composite's workers have real sessions and memory of their own, so anything that
  /// discards loops wholesale has to be able to visit them without knowing how deep
  /// the nesting goes.
  public var nodesAtAnyDepth: [LoopNode] {
    nodes.flatMap { [$0] + ($0.subGraph?.nodesAtAnyDepth ?? []) }
  }

  /// A structural copy with brand-new identities throughout — same loops, same wiring,
  /// nothing shared with the original.
  ///
  /// Required when instantiating a `.composite` template: a node's id *is* its `zmx`
  /// session name (`SurfaceRef(id:).zmxSessionName`), so a value-copied sub-graph would
  /// have every spawned instance attaching to the very same sessions as the template and
  /// as each other. Two instances would then be driving one terminal.
  ///
  /// Edge endpoints are remapped through the same table, so the copied graph keeps its
  /// shape. Fire counts reset — a fresh instance has not handed anything off yet.
  public func reIdentified() -> LoopGraph {
    var identities: [UUID: UUID] = [:]
    for node in nodes { identities[node.id] = UUID() }

    var copy = LoopGraph(id: UUID(), scope: scope)
    for node in nodes {
      var fresh = node
      fresh = LoopNode(
        id: identities[node.id] ?? UUID(),
        title: node.title,
        loopType: node.loopType,
        checkDescription: node.checkDescription,
        triggerPrompt: node.triggerPrompt,
        goal: node.goal,
        backend: node.backend,
        modelTier: node.modelTier,
        worktreeBinding: node.worktreeBinding,
        // Recursive on purpose: a composite nested inside a composite needs the same
        // treatment, for the same reason.
        subGraph: node.subGraph?.reIdentified(),
        pilotState: node.pilotState,
        state: node.loopType == .goalBased ? .running : .idle)
      copy.nodes.append(fresh)
    }
    for edge in edges {
      guard let from = identities[edge.from], let to = identities[edge.to] else { continue }
      copy.edges.append(LoopEdge(from: from, to: to, spec: edge.spec))
    }
    return copy
  }

  // MARK: - Start anchors

  /// The nodes that hang directly off the canvas's start marker — the graph's entry
  /// points (see docs/06-ux-terminals.md#graph-canvas).
  ///
  /// A graph of loops is usually several unrelated chains rather than one tree, so an
  /// un-anchored canvas reads as scattered cards with no beginning. Drawing a single
  /// start marker and running a line to each entry point gives the whole thing one
  /// origin to be read from, without inventing edges between loops that have nothing to
  /// do with each other.
  ///
  /// Entry point means "nothing hands off to it". Every other node is already reachable
  /// by walking edges backwards from one — with one exception: a component that is a
  /// pure cycle has no such node at all, so it would float free. Those get their first
  /// node anchored so the "everything descends from start" reading holds for every
  /// shape a graph can take.
  ///
  /// Loops with no edge in either direction.
  ///
  /// Kept apart from `entryPoints` on purpose. By the "nothing hands off to it" rule a
  /// loose loop is a root, and treating it as one is how ten unwired loops became a
  /// ten-line starburst from a single dot. A loop that runs nothing and is run by
  /// nothing is usually an accident, and the canvas says so rather than dressing it up
  /// as the beginning of a graph.
  public var unwiredNodeIDs: Set<UUID> {
    let touched = Set(edges.map(\.from)).union(edges.map(\.to))
    return Set(nodes.map(\.id).filter { !touched.contains($0) })
  }

  /// Where the graph actually begins: nothing hands off to these, and they hand off to
  /// something. Returned in `nodes` order so the canvas doesn't reshuffle between
  /// renders.
  public var sequencingEdges: [LoopEdge] { edges.filter { $0.kind.blocksTarget } }

  /// The titles of the loops a node is still waiting on — the sources of its unfired
  /// sequencing edges, in `nodes` order. What a surface names when it has to say *why*
  /// a blocked loop is blocked, rather than leaving the state word to explain itself.
  public func unfiredUpstreamTitles(of nodeID: UUID) -> [String] {
    let sources = Set(sequencingEdges.filter { $0.to == nodeID && !$0.fired }.map(\.from))
    return nodes.filter { sources.contains($0.id) }.map(\.title)
  }

  public var entryPoints: [UUID] {
    let targeted = Set(sequencingEdges.map(\.to))
    let loose = unwiredNodeIDs
    return nodes.map(\.id).filter { !targeted.contains($0) && !loose.contains($0) }
  }

  /// Nodes in a component that has no entry point at all — a closed cycle, where every
  /// node is handed off to by another.
  ///
  /// Worth naming because the honest thing to draw for one is *not* a root:
  /// `startAnchors` has to pick one arbitrarily to keep "everything descends from a
  /// beginning" true, and a card marked "entry" on the strength of an arbitrary pick is
  /// a card telling a lie the graph can't back up.
  public var cycleOnlyNodeIDs: Set<UUID> {
    var reached = Set(entryPoints)
    var frontier = entryPoints
    while let current = frontier.popLast() {
      for edge in sequencingEdges where edge.from == current && !reached.contains(edge.to) {
        reached.insert(edge.to)
        frontier.append(edge.to)
      }
    }
    let loose = unwiredNodeIDs
    return Set(nodes.map(\.id).filter { !reached.contains($0) && !loose.contains($0) })
  }

  /// Returned in `nodes` order, so the canvas's lines don't reshuffle between renders.
  ///
  /// Sketches are excluded before roots are picked: a sketch is not a graph beginning,
  /// and a fresh one — edgeless by construction — would otherwise claim an entry port
  /// the moment it was created.
  public var startAnchors: [UUID] {
    let targeted = Set(sequencingEdges.map(\.to))
    let entries = nodes.filter { $0.loopType != .sketch }.map(\.id)
      .filter { !targeted.contains($0) }

    var anchored = Set(entries)
    // Walk out from the entry points; whatever the walk never reaches is a cycle-only
    // component, and the first of its nodes becomes that component's anchor.
    var reached = anchored
    var frontier = entries
    while let current = frontier.popLast() {
      for edge in sequencingEdges where edge.from == current && !reached.contains(edge.to) {
        reached.insert(edge.to)
        frontier.append(edge.to)
      }
    }
    for node in nodes where !reached.contains(node.id) && node.loopType != .sketch {
      anchored.insert(node.id)
      var frontier = [node.id]
      reached.insert(node.id)
      while let current = frontier.popLast() {
        for edge in sequencingEdges where edge.from == current && !reached.contains(edge.to) {
          reached.insert(edge.to)
          frontier.append(edge.to)
        }
      }
    }
    return nodes.map(\.id).filter(anchored.contains)
  }

  /// The sidebar's top-level rows: `startAnchors`, then any sketch nothing points at.
  ///
  /// A sketch is deliberately never a canvas entry port — that is what `startAnchors`
  /// excludes it for — but a row is not a port: a loop the sidebar cannot show is a
  /// loop that effectively doesn't exist. Untargeted sketches append after the anchored
  /// roots, the sidebar's echo of the canvas's "sketches sit below the lanes"; a sketch
  /// something points at already lists as that node's child.
  public var sidebarRoots: [UUID] {
    let targeted = Set(edges.map(\.to))
    let sketches = nodes.filter { $0.loopType == .sketch && !targeted.contains($0.id) }
      .map(\.id)
    return startAnchors + sketches
  }

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case id, nodes, edges, artifactory
    /// Persisted as a `ProjectRef` rather than as the scope enum. Every graph on disk
    /// predates `LoopGraphScope`, and the ref round-trips both cases losslessly (the
    /// global graph's reserved path decodes straight back to `.global`), so there was
    /// nothing to gain from a new representation that older files wouldn't have.
    case project
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    let ref = try container.decode(ProjectRef.self, forKey: .project)
    scope = LoopGraphScope(projectPath: ref.path, name: ref.name)
    nodes = try container.decodeIfPresent(IdentifiedArrayOf<LoopNode>.self, forKey: .nodes) ?? []
    edges = try container.decodeIfPresent(IdentifiedArrayOf<LoopEdge>.self, forKey: .edges) ?? []
    artifactory = try container.decodeIfPresent([ArtifactoryPost].self, forKey: .artifactory) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(project, forKey: .project)
    try container.encode(nodes, forKey: .nodes)
    try container.encode(edges, forKey: .edges)
    // Absent while empty, so a graph file nobody has posted to stays byte-for-byte
    // what it was — the same reason `hasActiveDependents` never reaches disk.
    if !artifactory.isEmpty { try container.encode(artifactory, forKey: .artifactory) }
  }
}
