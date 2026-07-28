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

  /// A structural copy with brand-new identities throughout — same loops, same wiring,
  /// nothing shared with the original.
  ///
  /// Required when instantiating a `.proactive` template: a node's id *is* its `zmx`
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
  /// Returned in `nodes` order, so the canvas's lines don't reshuffle between renders.
  public var startAnchors: [UUID] {
    let targeted = Set(edges.map(\.to))
    let entries = nodes.map(\.id).filter { !targeted.contains($0) }

    var anchored = Set(entries)
    // Walk out from the entry points; whatever the walk never reaches is a cycle-only
    // component, and the first of its nodes becomes that component's anchor.
    var reached = anchored
    var frontier = entries
    while let current = frontier.popLast() {
      for edge in edges where edge.from == current && !reached.contains(edge.to) {
        reached.insert(edge.to)
        frontier.append(edge.to)
      }
    }
    for node in nodes where !reached.contains(node.id) {
      anchored.insert(node.id)
      var frontier = [node.id]
      reached.insert(node.id)
      while let current = frontier.popLast() {
        for edge in edges where edge.from == current && !reached.contains(edge.to) {
          reached.insert(edge.to)
          frontier.append(edge.to)
        }
      }
    }
    return nodes.map(\.id).filter(anchored.contains)
  }

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case id, nodes, edges
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
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(project, forKey: .project)
    try container.encode(nodes, forKey: .nodes)
    try container.encode(edges, forKey: .edges)
  }
}
