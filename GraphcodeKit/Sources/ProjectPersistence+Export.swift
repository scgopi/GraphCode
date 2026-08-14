import Foundation
import IdentifiedCollections

extension ProjectPersistence {
  /// Exports a subset of nodes from a graph into a shareable bundle.
  ///
  /// - Parameters:
  ///   - nodeIDs: UUIDs of nodes to export
  ///   - graph: The source graph containing the nodes
  ///   - projectPath: Project path (for memory lookups)
  ///   - includeChildren: If true, recursively include all child nodes of composites
  ///   - includeMemory: If true, include session logs and memory
  ///   - createdBy: Optional creator attribution
  /// - Returns: An in-memory export bundle ready to be zipped
  public func createExportBundle(
    for nodeIDs: [UUID],
    from graph: LoopGraph,
    projectPath: String,
    includeChildren: Bool = false,
    includeMemory: Bool = true,
    createdBy: String? = nil
  ) -> GraphExportBundle? {
    var nodeIDsToExport = Set(nodeIDs)

    if includeChildren {
      for nodeID in nodeIDs {
        let descendants = findDescendants(of: nodeID, in: graph)
        nodeIDsToExport.formUnion(descendants)
      }
    }

    let nodeIDStrings = nodeIDsToExport.map(\.uuidString)

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
      nodeIDs: nodeIDStrings,
      includesChildren: includeChildren,
      isFullGraph: Set(graph.nodes.map(\.id)) == nodeIDsToExport,
      sourceProject: projectPath,
      includesMemory: includeMemory
    )

    let manifest = ExportManifest(
      createdBy: createdBy,
      contents: contents
    )

    return GraphExportBundle(
      manifest: manifest,
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
    let nodeIDStrings = graph.nodes.map { $0.id.uuidString }

    var memoryByNodeID: [String: [String]] = [:]
    for node in graph.nodes {
      let entries = NodeMemory.entries(forProjectPath: projectPath, nodeID: node.id)
      if !entries.isEmpty {
        memoryByNodeID[node.id.uuidString] = entries
      }
    }

    let contents = ExportContents(
      nodeIDs: nodeIDStrings,
      includesChildren: false,
      isFullGraph: true,
      sourceProject: projectPath,
      includesMemory: true
    )

    let manifest = ExportManifest(createdBy: createdBy, contents: contents)

    return GraphExportBundle(
      manifest: manifest,
      graphSnapshot: graph,
      memoryByNodeID: memoryByNodeID
    )
  }

  /// Imports an export bundle into a target graph, remapping node IDs and creating
  /// new sessions. Returns the updated graph and a mapping of old→new node IDs.
  ///
  /// - Parameters:
  ///   - bundle: The export bundle to import
  ///   - targetGraph: The graph to merge into
  ///   - projectPath: Project path for writing memory files
  ///   - asChildOf: Optional parent node ID (creates a parent-child relationship)
  /// - Returns: Result with updated graph and ID mapping, or nil on validation failure
  public func importExportBundle(
    _ bundle: GraphExportBundle,
    into targetGraph: LoopGraph,
    projectPath: String,
    asChildOf parentID: UUID? = nil
  ) -> ImportResult? {
    // Validate manifest
    guard bundle.manifest.formatVersion == "1.0" else { return nil }

    // Create fresh identities for all imported nodes
    var idMapping: [String: UUID] = [:]
    var oldIDToNew: [UUID: UUID] = [:]

    for node in bundle.graphSnapshot.nodes {
      let newID = UUID()
      idMapping[node.id.uuidString] = newID
      oldIDToNew[node.id] = newID
    }

    // Re-identify the graph with new UUIDs
    var importedNodes: IdentifiedArrayOf<LoopNode> = []
    for node in bundle.graphSnapshot.nodes {
      guard let newID = oldIDToNew[node.id] else { continue }

      let remappedSubGraph = node.subGraph.map { remapSubGraph($0, mapping: oldIDToNew) }

      let freshNode = LoopNode(
        id: newID,
        title: node.title,
        loopType: node.loopType,
        checkDescription: node.checkDescription,
        triggerPrompt: node.triggerPrompt,
        firstInstruction: node.firstInstruction,
        pausesBeforeWritesOnly: node.pausesBeforeWritesOnly,
        goal: node.goal,
        backend: node.backend,
        modelTier: node.modelTier,
        worktreeBinding: node.worktreeBinding,
        subGraph: remappedSubGraph,
        pilotState: node.pilotState,
        usage: node.usage,
        activity: nil,
        summary: node.summary,
        presence: nil,
        metricHistory: node.metricHistory,
        createdBy: node.createdBy,
        state: node.state,
        createdAt: Date()
      )
      importedNodes.append(freshNode)
    }

    // Re-identify edges
    var importedEdges: IdentifiedArrayOf<LoopEdge> = []
    for edge in bundle.graphSnapshot.edges {
      guard let newFrom = oldIDToNew[edge.from],
            let newTo = oldIDToNew[edge.to]
      else { continue }

      let freshEdge = LoopEdge(
        id: UUID(),
        from: newFrom,
        to: newTo,
        kind: edge.kind,
        condition: edge.condition,
        payloadTransform: edge.payloadTransform,
        cycleGuard: edge.cycleGuard,
        spawnTargetProjectPath: edge.spawnTargetProjectPath,
        fireCount: 0
      )
      importedEdges.append(freshEdge)
    }

    // Merge into target graph
    var mergedGraph = targetGraph
    mergedGraph.nodes.append(contentsOf: importedNodes)
    mergedGraph.edges.append(contentsOf: importedEdges)

    // If importing as child, create an edge to the parent
    if let parentID = parentID,
       let firstImportedNode = importedNodes.first
    {
      let parentEdge = LoopEdge(
        from: parentID,
        to: firstImportedNode.id,
        spec: EdgeSpec(kind: .spawn, condition: .onSuccess)
      )
      mergedGraph.edges.append(parentEdge)
    }

    // Restore memory for each imported node
    for (oldIDStr, entries) in bundle.memoryByNodeID {
      guard let newID = idMapping[oldIDStr] else { continue }
      for entry in entries {
        NodeMemory.append(entry, projectPath: projectPath, nodeID: newID)
      }
    }

    let summary = "Imported \(importedNodes.count) node(s) with \(importedEdges.count) edge(s)"
    return ImportResult(
      nodeIDMapping: idMapping,
      updatedGraph: mergedGraph,
      summary: summary
    )
  }

  // MARK: - Helpers

  private func findDescendants(of nodeID: UUID, in graph: LoopGraph) -> Set<UUID> {
    var descendants = Set<UUID>()
    var frontier = [nodeID]

    while let current = frontier.popLast() {
      for edge in graph.edges where edge.from == current && !descendants.contains(edge.to) {
        descendants.insert(edge.to)
        frontier.append(edge.to)
      }

      if let node = graph.nodes[id: current], let subGraph = node.subGraph {
        for subNode in subGraph.nodes {
          descendants.insert(subNode.id)
          frontier.append(subNode.id)
        }
      }
    }

    return descendants
  }

  private func remapSubGraph(_ graph: LoopGraph, mapping: [UUID: UUID]) -> LoopGraph {
    var remappedNodes: IdentifiedArrayOf<LoopNode> = []
    for node in graph.nodes {
      guard let newID = mapping[node.id] else { continue }
      let remappedSubGraph = node.subGraph.map { remapSubGraph($0, mapping: mapping) }

      let freshNode = LoopNode(
        id: newID,
        title: node.title,
        loopType: node.loopType,
        checkDescription: node.checkDescription,
        triggerPrompt: node.triggerPrompt,
        firstInstruction: node.firstInstruction,
        pausesBeforeWritesOnly: node.pausesBeforeWritesOnly,
        goal: node.goal,
        backend: node.backend,
        modelTier: node.modelTier,
        worktreeBinding: node.worktreeBinding,
        subGraph: remappedSubGraph,
        pilotState: node.pilotState,
        usage: node.usage,
        activity: node.activity,
        summary: node.summary,
        presence: node.presence,
        metricHistory: node.metricHistory,
        createdBy: node.createdBy,
        state: node.state,
        createdAt: node.createdAt
      )
      remappedNodes.append(freshNode)
    }

    var remappedEdges: IdentifiedArrayOf<LoopEdge> = []
    for edge in graph.edges {
      guard let newFrom = mapping[edge.from], let newTo = mapping[edge.to] else { continue }
      let freshEdge = LoopEdge(
        id: edge.id,
        from: newFrom,
        to: newTo,
        kind: edge.kind,
        condition: edge.condition,
        payloadTransform: edge.payloadTransform,
        cycleGuard: edge.cycleGuard,
        spawnTargetProjectPath: edge.spawnTargetProjectPath,
        fireCount: edge.fireCount
      )
      remappedEdges.append(freshEdge)
    }

    return LoopGraph(
      id: graph.id,
      scope: graph.scope,
      nodes: remappedNodes,
      edges: remappedEdges
    )
  }
}
