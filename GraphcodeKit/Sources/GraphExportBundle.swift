import Foundation

/// Metadata about what's included in an export bundle — version, timestamp, scope.
public struct ExportManifest: Codable, Sendable {
  /// Version of the export format, for forward compatibility.
  public let formatVersion: String

  /// When the export was created.
  public let timestamp: Date

  /// Who created it (if known).
  public let createdBy: String?

  /// What's included in this bundle.
  public let contents: ExportContents

  /// Mapping of original node IDs to new IDs (populated on import, empty on export).
  public let nodeIDMapping: [String: String]?

  public init(
    timestamp: Date = Date(),
    createdBy: String? = nil,
    contents: ExportContents,
    nodeIDMapping: [String: String]? = nil
  ) {
    self.formatVersion = "1.0"
    self.timestamp = timestamp
    self.createdBy = createdBy
    self.contents = contents
    self.nodeIDMapping = nodeIDMapping
  }
}

/// Describes what's included in the export.
public struct ExportContents: Codable, Sendable {
  /// IDs of exported nodes.
  public let nodeIDs: [String]

  /// Whether all child nodes of a composite are included.
  public let includesChildren: Bool

  /// Whether this is a full graph export or a subset.
  public let isFullGraph: Bool

  /// Original project path (informational).
  public let sourceProject: String?

  /// Whether session memory logs are included.
  public let includesMemory: Bool

  public init(
    nodeIDs: [String],
    includesChildren: Bool = false,
    isFullGraph: Bool = false,
    sourceProject: String? = nil,
    includesMemory: Bool = true
  ) {
    self.nodeIDs = nodeIDs
    self.includesChildren = includesChildren
    self.isFullGraph = isFullGraph
    self.sourceProject = sourceProject
    self.includesMemory = includesMemory
  }
}

/// In-memory representation of what gets zipped. Separates the bundle structure
/// from file I/O concerns.
public struct GraphExportBundle: Sendable {
  /// Manifest describing the bundle contents.
  public let manifest: ExportManifest

  /// The graph snapshot (nodes + edges).
  public let graphSnapshot: LoopGraph

  /// Session memory entries keyed by node ID string.
  public let memoryByNodeID: [String: [String]]

  /// Original prompt text, keyed by node ID string (if available).
  public let promptsByNodeID: [String: String]

  public init(
    manifest: ExportManifest,
    graphSnapshot: LoopGraph,
    memoryByNodeID: [String: [String]] = [:],
    promptsByNodeID: [String: String] = [:]
  ) {
    self.manifest = manifest
    self.graphSnapshot = graphSnapshot
    self.memoryByNodeID = memoryByNodeID
    self.promptsByNodeID = promptsByNodeID
  }
}

/// Result of an import, tracking what was created/updated.
public struct ImportResult: Sendable {
  /// Mapping of imported node IDs (as strings) to new node IDs in the target graph.
  public let nodeIDMapping: [String: UUID]

  /// The updated graph after import.
  public let updatedGraph: LoopGraph

  /// Human-readable summary of what was imported.
  public let summary: String

  public init(
    nodeIDMapping: [String: UUID],
    updatedGraph: LoopGraph,
    summary: String
  ) {
    self.nodeIDMapping = nodeIDMapping
    self.updatedGraph = updatedGraph
    self.summary = summary
  }
}
