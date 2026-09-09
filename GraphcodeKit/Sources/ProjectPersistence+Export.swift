import Foundation
import IdentifiedCollections

extension ProjectPersistence {
  /// Collects the named loops — and, by default, everything descended from them —
  /// into a shareable bundle: the graph slice plus each loop's memory log.
  ///
  /// Descendants come from two relationships, because the graph records "child" two
  /// ways: edges drawn out of the node (hand-offs, spawns), and `createdBy` custody —
  /// a loop a session created through the CLI has a custodian even when no edge was
  /// ever drawn. Following only edges exported a coordinator without the workers it
  /// fanned out.
  ///
  /// Import is *not* the mirror of this call: the daemon owns the live graph, so a
  /// bundle goes back in through `GraphCommand.importNodes`, never by writing the
  /// graph file from a client.
  ///
  /// Sessions are read off this Mac's disk — right for a local project. A remote
  /// project's sessions are on its host, and this call would leave them behind; the
  /// `async` twin below fetches them over the ssh dial.
  public func createExportBundle(
    for nodeIDs: [UUID],
    from graph: LoopGraph,
    projectPath: String,
    includeChildren: Bool = true,
    includeMemory: Bool = true,
    createdBy: String? = nil
  ) -> GraphExportBundle? {
    guard let slice = slice(of: graph, for: nodeIDs, includeChildren: includeChildren)
    else { return nil }
    return bundle(
      slice, projectPath: projectPath, includeMemory: includeMemory, createdBy: createdBy,
      sessions: Self.sessionArtifacts(for: slice.nodes, projectPath: projectPath))
  }

  /// The same bundle, with sessions collected wherever the project actually lives: a
  /// remote project's are fetched from its host (`SessionTransplant.exportRemoteArtifact`),
  /// a local project's are read off this disk exactly as the synchronous call does. The
  /// app and the CLI export through this one so an ssh:// or codespace:// export carries
  /// its conversations (issue #333).
  public func createExportBundle(
    for nodeIDs: [UUID],
    from graph: LoopGraph,
    projectPath: String,
    includeChildren: Bool = true,
    includeMemory: Bool = true,
    createdBy: String? = nil
  ) async -> GraphExportBundle? {
    guard let slice = slice(of: graph, for: nodeIDs, includeChildren: includeChildren)
    else { return nil }
    let sessions = await Self.remoteAwareSessionArtifacts(
      for: slice.nodes, projectPath: projectPath)
    return bundle(
      slice, projectPath: projectPath, includeMemory: includeMemory, createdBy: createdBy,
      sessions: sessions)
  }

  /// Exports an entire graph as a shareable bundle. Sessions come off this disk, as in
  /// `createExportBundle`; the `async` twin reaches a remote project's host.
  public func createFullGraphExportBundle(
    for graph: LoopGraph,
    projectPath: String,
    createdBy: String? = nil
  ) -> GraphExportBundle {
    bundle(
      Slice(graph: graph, nodes: Array(graph.nodes), isFullGraph: true, includesChildren: true),
      projectPath: projectPath, includeMemory: true, createdBy: createdBy,
      sessions: Self.sessionArtifacts(for: graph.nodes, projectPath: projectPath))
  }

  /// The whole graph with sessions collected from wherever the project lives — see the
  /// `async` `createExportBundle`.
  public func createFullGraphExportBundle(
    for graph: LoopGraph,
    projectPath: String,
    createdBy: String? = nil
  ) async -> GraphExportBundle {
    let sessions = await Self.remoteAwareSessionArtifacts(
      for: graph.nodes, projectPath: projectPath)
    return bundle(
      Slice(graph: graph, nodes: Array(graph.nodes), isFullGraph: true, includesChildren: true),
      projectPath: projectPath, includeMemory: true, createdBy: createdBy, sessions: sessions)
  }

  /// Each exported loop's backend conversation, where one exists and the backend can
  /// carry it — see `SessionTransplant`. Local disk only.
  static func sessionArtifacts(
    for nodes: some Sequence<LoopNode>, projectPath: String
  ) -> [String: SessionTransplant.Artifact] {
    var artifacts: [String: SessionTransplant.Artifact] = [:]
    for node in nodes {
      if let artifact = SessionTransplant.exportArtifact(forNode: node, projectPath: projectPath) {
        artifacts[node.id.uuidString] = artifact
      }
    }
    return artifacts
  }

  /// How many remote fetches run at once. Each is its own dial — multiplexed over one
  /// connection for a plain host, a fresh `gh` tunnel per loop for a Codespace — plus
  /// a `tar` and a watchdog; a thirty-loop Codespace graph fetched all at once would be
  /// thirty tunnels racing to start a stopped codespace. Four keeps the export quick on
  /// a live host without turning it into that.
  static let remoteSessionFetchConcurrency = 4

  /// `sessionArtifacts` for a project on any host. A remote project's loops are fetched
  /// `remoteSessionFetchConcurrency` at a time — the next dial starts as one finishes —
  /// and a loop whose fetch comes back empty is simply exported without a session: the
  /// export never fails on one.
  static func remoteAwareSessionArtifacts(
    for nodes: some Sequence<LoopNode>, projectPath: String
  ) async -> [String: SessionTransplant.Artifact] {
    guard let remote = RemoteProjectLocation.parse(projectPath: projectPath) else {
      return sessionArtifacts(for: nodes, projectPath: projectPath)
    }
    return await withTaskGroup(of: (String, SessionTransplant.Artifact?).self) { group in
      var artifacts: [String: SessionTransplant.Artifact] = [:]
      var inFlight = 0
      for node in nodes {
        if inFlight == remoteSessionFetchConcurrency, let (nodeID, artifact) = await group.next() {
          inFlight -= 1
          if let artifact { artifacts[nodeID] = artifact }
        }
        inFlight += 1
        group.addTask {
          (
            node.id.uuidString,
            await SessionTransplant.exportRemoteArtifact(forNode: node, at: remote)
          )
        }
      }
      for await (nodeID, artifact) in group {
        if let artifact { artifacts[nodeID] = artifact }
      }
      return artifacts
    }
  }

  /// The part of a graph an export names: the snapshot to write and the loops it holds.
  private struct Slice {
    var graph: LoopGraph
    var nodes: [LoopNode]
    var isFullGraph: Bool
    var includesChildren: Bool
  }

  private func slice(of graph: LoopGraph, for nodeIDs: [UUID], includeChildren: Bool) -> Slice? {
    var nodeIDsToExport = Set(nodeIDs)
    if includeChildren {
      for nodeID in nodeIDs {
        nodeIDsToExport.formUnion(descendants(of: nodeID, in: graph))
      }
    }
    let exportedNodes = graph.nodes.filter { nodeIDsToExport.contains($0.id) }
    guard !exportedNodes.isEmpty else { return nil }
    let exportedEdges = graph.edges.filter {
      nodeIDsToExport.contains($0.from) && nodeIDsToExport.contains($0.to)
    }
    let exportGraph = LoopGraph(
      id: graph.id,
      scope: graph.scope,
      nodes: IdentifiedArray(uniqueElements: exportedNodes),
      edges: IdentifiedArray(uniqueElements: exportedEdges)
    )
    return Slice(
      graph: exportGraph, nodes: Array(exportedNodes),
      isFullGraph: Set(graph.nodes.map(\.id)) == nodeIDsToExport,
      includesChildren: includeChildren)
  }

  private func bundle(
    _ slice: Slice, projectPath: String, includeMemory: Bool, createdBy: String?,
    sessions: [String: SessionTransplant.Artifact]
  ) -> GraphExportBundle {
    var memoryByNodeID: [String: [String]] = [:]
    if includeMemory {
      for node in slice.nodes {
        let entries = NodeMemory.entries(forProjectPath: projectPath, nodeID: node.id)
        if !entries.isEmpty {
          memoryByNodeID[node.id.uuidString] = entries
        }
      }
    }
    let contents = ExportContents(
      nodeIDs: slice.nodes.map(\.id.uuidString),
      includesChildren: slice.includesChildren,
      isFullGraph: slice.isFullGraph,
      sourceProject: projectPath,
      includesMemory: includeMemory
    )
    return GraphExportBundle(
      manifest: ExportManifest(createdBy: createdBy, contents: contents),
      graphSnapshot: slice.graph,
      memoryByNodeID: memoryByNodeID,
      sessionsByNodeID: sessions
    )
  }

  /// Everything downstream of `nodeID`: edge targets, custody children
  /// (`createdBy`), and the contents of composite sub-graphs, transitively.
  private func descendants(of nodeID: UUID, in graph: LoopGraph) -> Set<UUID> {
    var found = Set<UUID>()
    var frontier = [nodeID]

    while let current = frontier.popLast() {
      for edge in graph.edges where edge.from == current && !found.contains(edge.to) {
        found.insert(edge.to)
        frontier.append(edge.to)
      }
      for node in graph.nodes where node.createdBy == current && !found.contains(node.id) {
        found.insert(node.id)
        frontier.append(node.id)
      }
      if let sub = graph.nodes[id: current]?.subGraph {
        for subNode in sub.nodes where !found.contains(subNode.id) {
          found.insert(subNode.id)
          frontier.append(subNode.id)
        }
      }
    }
    return found
  }
}
