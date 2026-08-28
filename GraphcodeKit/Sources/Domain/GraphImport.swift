import Foundation
import IdentifiedCollections

/// What a client hands the daemon to import loops it read out of an export bundle —
/// the wire half of `GraphExportBundle`, carrying only what the daemon needs.
///
/// The daemon, not the client, performs the merge: `graphcoded` owns the live
/// `LoopGraph`, so a client that wrote the merged graph to disk itself would have its
/// work silently clobbered by the daemon's next save. (That was the first import
/// implementation, and it did.) Sending the snapshot through `GraphCommand.importNodes`
/// puts the mutation where every other mutation lives, and the `.graphChanged`
/// broadcast keeps every open window agreeing about what just arrived.
public struct GraphImportRequest: Codable, Sendable, Equatable {
  /// The exported nodes and the edges between them, exactly as the bundle carried
  /// them. Ids are the *source* graph's — the daemon re-identifies everything on
  /// arrival, so a bundle can be imported twice, or into the graph it came from.
  public var snapshot: LoopGraph
  /// Each exported node's memory log entries, keyed by the node's *original* id
  /// string. Restored under the fresh ids so an imported loop wakes knowing what its
  /// ancestor learned.
  public var memoryByNodeID: [String: [String]]
  /// When set, the imported subgraph's entry points are wired under this existing
  /// node with `.spawn` edges — "import as children of this loop".
  public var asChildOf: UUID?
  /// Whether the client already re-identified the snapshot
  /// (`GraphImportPlanner.reIdentified`). A client that restores session transplants
  /// has to know each loop's fresh id *before* sending — the banked session id and
  /// transcript are keyed by it — so it remaps first and the daemon splices verbatim,
  /// refusing on any id collision instead of remapping a second time. Absent (an
  /// older client), the daemon re-identifies on arrival as it always did.
  public var identitiesAreFresh: Bool

  public init(
    snapshot: LoopGraph, memoryByNodeID: [String: [String]] = [:], asChildOf: UUID? = nil,
    identitiesAreFresh: Bool = false
  ) {
    self.snapshot = snapshot
    self.memoryByNodeID = memoryByNodeID
    self.asChildOf = asChildOf
    self.identitiesAreFresh = identitiesAreFresh
  }

  private enum CodingKeys: String, CodingKey {
    case snapshot, memoryByNodeID, asChildOf, identitiesAreFresh
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    snapshot = try container.decode(LoopGraph.self, forKey: .snapshot)
    memoryByNodeID =
      try container.decodeIfPresent([String: [String]].self, forKey: .memoryByNodeID) ?? [:]
    asChildOf = try container.decodeIfPresent(UUID.self, forKey: .asChildOf)
    identitiesAreFresh =
      try container.decodeIfPresent(Bool.self, forKey: .identitiesAreFresh) ?? false
  }
}

/// Pure merge logic for an import: re-identify the incoming snapshot, splice it into
/// the target graph, and report which fresh id each original id became.
///
/// Free of I/O on purpose — `GraphStore` applies the plan to its live graph and
/// routes memory through its own hooks, and tests can exercise the remap without a
/// daemon. Distinct from `LoopGraph.reIdentified()` (the composite-template copy):
/// that rebuild drops history fields a template shouldn't carry, where an import
/// preserves them — usage, metric history, summary — because the bundle *is* the
/// loop's history.
public enum GraphImportPlanner {
  public struct Plan: Sendable {
    /// The target graph with the re-identified nodes and edges appended.
    public var mergedGraph: LoopGraph
    /// Original id string → the fresh id it became, for restoring memory logs.
    public var idMapping: [String: UUID]
    /// The fresh ids of the imported subgraph's entry points, in snapshot order.
    public var importedEntryPoints: [UUID]
  }

  /// Client-side re-identification: the same remap `merge` would perform, done ahead
  /// of sending so the caller can key session transplants and other per-node
  /// restorations by the ids the loops will actually have. The returned request
  /// carries `identitiesAreFresh`, telling the daemon to splice verbatim.
  public static func reIdentified(
    _ request: GraphImportRequest
  ) -> (request: GraphImportRequest, idMapping: [String: UUID])? {
    let snapshot = request.snapshot
    guard !snapshot.nodes.isEmpty else { return nil }

    var identities: [UUID: UUID] = [:]
    collectIdentities(of: snapshot, into: &identities)

    var fresh = LoopGraph(id: UUID(), scope: snapshot.scope)
    for node in snapshot.nodes {
      guard let newID = identities[node.id] else { continue }
      fresh.nodes.append(reIdentify(node, as: newID, identities: identities))
    }
    for edge in snapshot.edges {
      guard let from = identities[edge.from], let to = identities[edge.to] else { continue }
      fresh.edges.append(LoopEdge(from: from, to: to, spec: edge.spec))
    }

    var idMapping: [String: UUID] = [:]
    for (old, new) in identities { idMapping[old.uuidString] = new }

    var remappedMemory: [String: [String]] = [:]
    for (oldID, entries) in request.memoryByNodeID {
      remappedMemory[idMapping[oldID]?.uuidString ?? oldID] = entries
    }

    let prepared = GraphImportRequest(
      snapshot: fresh, memoryByNodeID: remappedMemory, asChildOf: request.asChildOf,
      identitiesAreFresh: true)
    return (prepared, idMapping)
  }

  public static func merge(
    _ request: GraphImportRequest, into target: LoopGraph
  ) -> Plan? {
    let snapshot = request.snapshot
    guard !snapshot.nodes.isEmpty else { return nil }
    if let parent = request.asChildOf, target.nodes[id: parent] == nil { return nil }
    if request.identitiesAreFresh { return spliceVerbatim(request, into: target) }

    var identities: [UUID: UUID] = [:]
    collectIdentities(of: snapshot, into: &identities)

    var merged = target
    for node in snapshot.nodes {
      guard let newID = identities[node.id] else { continue }
      merged.nodes.append(reIdentify(node, as: newID, identities: identities))
    }
    for edge in snapshot.edges {
      guard let from = identities[edge.from], let to = identities[edge.to] else { continue }
      merged.edges.append(LoopEdge(from: from, to: to, spec: edge.spec))
    }

    // "Import as children": the snapshot's entry points hang off the chosen parent as
    // `.spawn` edges — the kind a loop fanning out work already draws — so the canvas
    // shows where the imported chain came from without gating it behind a hand-off.
    let entryPoints = importedEntryPoints(of: snapshot, identities: identities)
    if let parent = request.asChildOf {
      for entry in entryPoints {
        merged.edges.append(
          LoopEdge(from: parent, to: entry, spec: EdgeSpec(kind: .spawn)))
      }
    }

    var idMapping: [String: UUID] = [:]
    for (old, new) in identities { idMapping[old.uuidString] = new }
    return Plan(mergedGraph: merged, idMapping: idMapping, importedEntryPoints: entryPoints)
  }

  /// The already-re-identified path: the client ran `reIdentified`, so the ids are
  /// fresh and any collision with the target graph means the request is stale or
  /// replayed — refused, never silently re-remapped, because the client has already
  /// keyed session state to these exact ids.
  private static func spliceVerbatim(
    _ request: GraphImportRequest, into target: LoopGraph
  ) -> Plan? {
    let snapshot = request.snapshot
    for node in snapshot.nodes where target.containsAtAnyDepth(node.id) { return nil }

    var merged = target
    var idMapping: [String: UUID] = [:]
    for node in snapshot.nodes {
      merged.nodes.append(node)
      idMapping[node.id.uuidString] = node.id
    }
    for edge in snapshot.edges {
      merged.edges.append(edge)
    }
    let targeted = Set(snapshot.edges.map(\.to))
    let entryPoints = snapshot.nodes.map(\.id).filter { !targeted.contains($0) }
    if let parent = request.asChildOf {
      for entry in entryPoints {
        merged.edges.append(LoopEdge(from: parent, to: entry, spec: EdgeSpec(kind: .spawn)))
      }
    }
    return Plan(mergedGraph: merged, idMapping: idMapping, importedEntryPoints: entryPoints)
  }

  /// Fresh ids for every node at every depth — composites' contents included, so a
  /// nested sub-graph never re-attaches to the sessions of the graph it was exported
  /// from (a node's id *is* its `zmx` session name).
  private static func collectIdentities(of graph: LoopGraph, into table: inout [UUID: UUID]) {
    for node in graph.nodes {
      table[node.id] = UUID()
      if let sub = node.subGraph { collectIdentities(of: sub, into: &table) }
    }
  }

  /// A structural copy under a new id, keeping the fields that are the loop's history.
  ///
  /// A resolved loop keeps its verdict: the bundle *is* the loop's history, and a
  /// succeeded loop reborn `.idle` looked unstarted to every ensure path — on a remote
  /// project the liveness sweep re-ran finished work on a host nobody was watching.
  /// Everything else lands `.idle`, and the daemon starts the unattended ones the
  /// moment they arrive (`GraphStore.importNodes`), exactly as `createNode` would.
  /// `presence`/`activity` stay nil for the same reason they aren't persisted.
  private static func reIdentify(
    _ node: LoopNode, as newID: UUID, identities: [UUID: UUID]
  ) -> LoopNode {
    var remappedSubGraph: LoopGraph?
    if let sub = node.subGraph {
      var copy = LoopGraph(id: UUID(), scope: sub.scope)
      for subNode in sub.nodes {
        guard let subID = identities[subNode.id] else { continue }
        copy.nodes.append(reIdentify(subNode, as: subID, identities: identities))
      }
      for edge in sub.edges {
        guard let from = identities[edge.from], let to = identities[edge.to] else { continue }
        copy.edges.append(LoopEdge(from: from, to: to, spec: edge.spec))
      }
      remappedSubGraph = copy
    }
    return LoopNode(
      id: newID,
      title: node.title,
      loopType: node.loopType,
      checkDescription: node.checkDescription,
      triggerPrompt: node.triggerPrompt,
      heartbeatIntervalSeconds: node.heartbeatIntervalSeconds,
      firstInstruction: node.firstInstruction,
      pausesBeforeWritesOnly: node.pausesBeforeWritesOnly,
      goal: node.goal,
      backend: node.backend,
      modelTier: node.modelTier,
      // A worktree binding names paths on the exporting machine; carrying it over
      // would point the imported loop at a checkout that isn't there.
      worktreeBinding: nil,
      subGraph: remappedSubGraph,
      pilotState: node.pilotState,
      usage: node.usage,
      summary: node.summary,
      metricHistory: node.metricHistory,
      // Custody only survives when the custodian came along in the same bundle;
      // otherwise the reference would dangle at a node the target graph never had.
      createdBy: node.createdBy.flatMap { identities[$0] },
      state: node.isResolved ? node.state : .idle,
      createdAt: Date()
    )
  }

  private static func importedEntryPoints(
    of snapshot: LoopGraph, identities: [UUID: UUID]
  ) -> [UUID] {
    let targeted = Set(snapshot.edges.map(\.to))
    return snapshot.nodes.map(\.id)
      .filter { !targeted.contains($0) }
      .compactMap { identities[$0] }
  }
}
