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

  /// Each loop's backend conversation, keyed by node ID string — what lets an
  /// imported loop resume where the exported one left off. See `SessionTransplant`
  /// for what each backend can carry.
  public let sessionsByNodeID: [String: SessionTransplant.Artifact]

  public init(
    manifest: ExportManifest,
    graphSnapshot: LoopGraph,
    memoryByNodeID: [String: [String]] = [:],
    promptsByNodeID: [String: String] = [:],
    sessionsByNodeID: [String: SessionTransplant.Artifact] = [:]
  ) {
    self.manifest = manifest
    self.graphSnapshot = graphSnapshot
    self.memoryByNodeID = memoryByNodeID
    self.promptsByNodeID = promptsByNodeID
    self.sessionsByNodeID = sessionsByNodeID
  }
}

extension GraphExportBundle {
  /// The wire request this bundle becomes when a client asks the daemon to import it —
  /// the daemon performs the merge (see `GraphImportRequest`).
  public func importRequest(asChildOf parent: UUID? = nil) -> GraphImportRequest {
    GraphImportRequest(
      snapshot: graphSnapshot, memoryByNodeID: memoryByNodeID, asChildOf: parent)
  }

  /// The full client half of an import: re-identify the snapshot here (so the fresh
  /// ids are known before anything is sent), install each carried session under its
  /// loop's fresh id, and hand back the request the daemon should splice verbatim —
  /// plus how many of those sessions were actually installed, so the caller can say
  /// "N will resume" and mean it.
  ///
  /// Session installation happens client-side on purpose: transcripts run to
  /// megabytes and belong on disk, not inside a socket frame — and every path they're
  /// written to (`~/.claude`, `~/.copilot`, `~/.graphcode/sessions`) is read fresh at
  /// launch time, so there is no daemon-held copy to race. A remote target gets the
  /// same installation on *its* disk, delivered over the ssh dial
  /// (`SessionTransplant.restoreRemote`) — which is why this is async, and why it must
  /// finish before the import command is sent: the daemon ensures an imported loop's
  /// session the moment it arrives, and the resume id has to already be banked on the
  /// host by then.
  public func preparedImportRequest(
    asChildOf parent: UUID? = nil, projectPath: String
  ) async -> (request: GraphImportRequest, resumingSessions: Int)? {
    guard
      let (request, idMapping) = GraphImportPlanner.reIdentified(
        importRequest(asChildOf: parent))
    else { return nil }
    let remote = RemoteProjectLocation.parse(projectPath: projectPath)
    var resuming = 0
    for (oldID, artifact) in sessionsByNodeID {
      guard let newID = idMapping[oldID] else { continue }
      let installed: String?
      if let remote {
        installed = await SessionTransplant.restoreRemote(
          artifact, forNodeID: newID, at: remote)
      } else {
        installed = SessionTransplant.restore(
          artifact, forNodeID: newID, projectPath: projectPath)
      }
      if installed != nil { resuming += 1 }
    }
    return (request, resuming)
  }
}
