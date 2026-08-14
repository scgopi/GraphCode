import Foundation

extension GraphExportBundle {
  /// Writes the bundle to a ZIP file at the specified path.
  ///
  /// Returns the path on success, or nil if writing failed.
  public func writeToZip(at path: String) -> String? {
    let fileURL = URL(fileURLWithPath: path)
    let tmpDir = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".export-tmp-\(UUID().uuidString)")

    do {
      try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpDir) }

      let manifestJSON = try JSONEncoder().encode(manifest)
      let manifestURL = tmpDir.appendingPathComponent("manifest.json")
      try manifestJSON.write(to: manifestURL)

      let graphJSON = try JSONEncoder().encode(graphSnapshot)
      let graphURL = tmpDir.appendingPathComponent("graph-snapshot.json")
      try graphJSON.write(to: graphURL)

      let memoryDir = tmpDir.appendingPathComponent("memory", isDirectory: true)
      for (nodeIDStr, entries) in memoryByNodeID {
        let nodeMemoryDir = memoryDir.appendingPathComponent(nodeIDStr, isDirectory: true)
        try FileManager.default.createDirectory(
          at: nodeMemoryDir, withIntermediateDirectories: true)

        let logContent = entries.joined(separator: "\n") + "\n"
        let logURL = nodeMemoryDir.appendingPathComponent(NodeMemory.logFileName)
        try logContent.write(to: logURL, atomically: true, encoding: .utf8)
      }

      let readmeURL = tmpDir.appendingPathComponent("README.md")
      let readmeContent = readmeMarkdown(for: manifest)
      try readmeContent.write(to: readmeURL, atomically: true, encoding: .utf8)

      try Self.createZipArchive(at: fileURL, from: tmpDir)
      return path
    } catch {
      return nil
    }
  }

  /// Reads a ZIP file and deserializes it into a GraphExportBundle.
  public static func readFromZip(at path: String) -> GraphExportBundle? {
    let fileURL = URL(fileURLWithPath: path)
    let tmpDir = fileURL.deletingLastPathComponent().appendingPathComponent(
      ".import-tmp-\(UUID().uuidString)")

    do {
      try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpDir) }

      try extractZipArchive(from: fileURL, to: tmpDir)

      let manifestURL = tmpDir.appendingPathComponent("manifest.json")
      guard let manifestData = try? Data(contentsOf: manifestURL) else { return nil }
      guard let manifest = try? JSONDecoder().decode(ExportManifest.self, from: manifestData) else {
        return nil
      }

      let graphURL = tmpDir.appendingPathComponent("graph-snapshot.json")
      guard let graphData = try? Data(contentsOf: graphURL) else { return nil }
      guard let graph = try? JSONDecoder().decode(LoopGraph.self, from: graphData) else {
        return nil
      }

      var memoryByNodeID: [String: [String]] = [:]
      let memoryDir = tmpDir.appendingPathComponent("memory")
      if FileManager.default.fileExists(atPath: memoryDir.path) {
        if let nodeIDs = try? FileManager.default.contentsOfDirectory(atPath: memoryDir.path) {
          for nodeID in nodeIDs {
            let logURL = memoryDir.appendingPathComponent(nodeID).appendingPathComponent(
              NodeMemory.logFileName)
            if let logContent = try? String(contentsOf: logURL, encoding: .utf8) {
              let entries = logContent.split(whereSeparator: \.isNewline).map(String.init)
              memoryByNodeID[nodeID] = entries
            }
          }
        }
      }

      return GraphExportBundle(
        manifest: manifest,
        graphSnapshot: graph,
        memoryByNodeID: memoryByNodeID
      )
    } catch {
      return nil
    }
  }

  // MARK: - ZIP Helpers

  private static func createZipArchive(at destination: URL, from source: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", source.path, destination.path]

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw ExportError.zipCreationFailed
    }
  }

  private static func extractZipArchive(from source: URL, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-q", source.path, "-d", destination.path]

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw ExportError.zipExtractionFailed
    }
  }

  private func readmeMarkdown(for manifest: ExportManifest) -> String {
    var lines: [String] = [
      "# GraphCode Export Bundle",
      "",
      "This bundle contains an exported GraphCode graph or subset of nodes, ready to import into another project.",
      "",
      "## Contents",
      "",
      "- **manifest.json** — Metadata about what's included",
      "- **graph-snapshot.json** — The LoopGraph with nodes and edges",
      "- **memory/** — Session logs for each node (LOG.txt entries)",
      "",
      "## How to Import",
      "",
      "```bash",
      "graphcode node import /path/to/this/export.zip --project /path/to/target/project",
      "```",
      "",
      "Or import as a child of an existing node:",
      "",
      "```bash",
      "graphcode node import /path/to/this/export.zip \\",
      "  --project /path/to/target/project \\",
      "  --as-child-of <parent-node-id>",
      "```",
      "",
      "## What Gets Imported",
      "",
      "- Node configuration (type, prompts, goals, backend, model tier)",
      "- Graph edges and connections (with UUID remapping to avoid collisions)",
      "- Session memory logs (history of what each node has done)",
      "- All sub-nodes if composite nodes are included",
      "",
      "## What's Fresh on Import",
      "",
      "- **Node IDs** are remapped to fresh UUIDs",
      "- **Session IDs** are created new (zmx, Copilot, Codex sessions reset)",
      "- **Fire counts** on edges reset to 0 (connections haven't fired yet in the target)",
      "- **Timestamps** are set to import time",
      "",
      "## Metadata",
      "",
    ]

    if let createdBy = manifest.createdBy {
      lines.append("**Created by:** \(createdBy)")
    }
    lines.append("**Created at:** \(manifest.timestamp.ISO8601Format())")
    lines.append("**Format version:** \(manifest.formatVersion)")
    lines.append("")
    lines.append("**Included nodes:** \(manifest.contents.nodeIDs.count)")
    lines.append("**Includes all children:** \(manifest.contents.includesChildren)")
    lines.append("**Is full graph export:** \(manifest.contents.isFullGraph)")
    lines.append("**Includes memory logs:** \(manifest.contents.includesMemory)")
    if let source = manifest.contents.sourceProject {
      lines.append("**Source project:** \(source)")
    }

    return lines.joined(separator: "\n")
  }
}

public enum ExportError: Error {
  case zipCreationFailed
  case zipExtractionFailed
  case invalidBundle
}
