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
  public func createExportBundle(
    for nodeIDs: [UUID],
    from graph: LoopGraph,
    projectPath: String,
    includeChildren: Bool = true,
    includeMemory: Bool = true,
    createdBy: String? = nil
  ) -> GraphExportBundle? {
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

    var memoryByNodeID: [String: [String]] = [:]
    if includeMemory {
      for nodeID in nodeIDsToExport {
        let entries = NodeMemory.entries(forProjectPath: projectPath, nodeID: nodeID)
        if !entries.isEmpty {
          memoryByNodeID[nodeID.uuidString] = entries
        }
      }
    }

    let contents = ExportContents(
      nodeIDs: nodeIDsToExport.map(\.uuidString),
      includesChildren: includeChildren,
      isFullGraph: Set(graph.nodes.map(\.id)) == nodeIDsToExport,
      sourceProject: projectPath,
      includesMemory: includeMemory
    )

    return GraphExportBundle(
      manifest: ExportManifest(createdBy: createdBy, contents: contents),
      graphSnapshot: exportGraph,
      memoryByNodeID: memoryByNodeID
    )
  }

  /// Exports an entire graph as a shareable bundle.
  public func createFullGraphExportBundle(
    for graph: LoopGraph,
    projectPath: String,
    createdBy: String? = nil
  ) -> GraphExportBundle {
    var memoryByNodeID: [String: [String]] = [:]
    for node in graph.nodes {
      let entries = NodeMemory.entries(forProjectPath: projectPath, nodeID: node.id)
      if !entries.isEmpty {
        memoryByNodeID[node.id.uuidString] = entries
      }
    }

    let contents = ExportContents(
      nodeIDs: graph.nodes.map { $0.id.uuidString },
      includesChildren: true,
      isFullGraph: true,
      sourceProject: projectPath,
      includesMemory: true
    )

    return GraphExportBundle(
      manifest: ExportManifest(createdBy: createdBy, contents: contents),
      graphSnapshot: graph,
      memoryByNodeID: memoryByNodeID
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
