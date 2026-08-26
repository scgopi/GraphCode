import Foundation

extension GraphExportBundle {
  /// Writes the bundle to a ZIP file at the specified path.
  ///
  /// Returns the path on success, or nil if writing failed.
  public func writeToZip(at path: String) -> String? {
    let fileURL = URL(fileURLWithPath: path)
    // Staged in the system temp dir, not beside the output: the output's folder is
    // writable but littering it with a staging directory a crash could orphan is rude,
    // and `readFromZip` needs the same choice anyway (its input may sit somewhere
    // read-only, like a mounted DMG).
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-export-\(UUID().uuidString)")

    do {
      try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpDir) }

      let manifestJSON = try Self.manifestEncoder().encode(manifest)
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

      let sessionsDir = tmpDir.appendingPathComponent("sessions", isDirectory: true)
      for (nodeIDStr, artifact) in sessionsByNodeID {
        let nodeDir = sessionsDir.appendingPathComponent(nodeIDStr, isDirectory: true)
        try FileManager.default.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        let meta: [String: String?] = [
          "backend": artifact.backend.rawValue,
          "sessionID": artifact.sessionID,
          "sourceWorkingDirectory": artifact.sourceWorkingDirectory,
        ]
        let metaData = try JSONSerialization.data(
          withJSONObject: meta.compactMapValues { $0 }, options: [.sortedKeys])
        try metaData.write(to: nodeDir.appendingPathComponent("meta.json"))
        for (relativePath, data) in artifact.files {
          let fileURL = nodeDir.appendingPathComponent("files")
            .appendingPathComponent(relativePath)
          try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
          try data.write(to: fileURL)
        }
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
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-import-\(UUID().uuidString)")

    do {
      try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmpDir) }

      try extractZipArchive(from: fileURL, to: tmpDir)

      let manifestURL = tmpDir.appendingPathComponent("manifest.json")
      guard let manifestData = try? Data(contentsOf: manifestURL) else { return nil }
      guard
        let manifest = try? manifestDecoder().decode(ExportManifest.self, from: manifestData)
      else { return nil }

      let graphURL = tmpDir.appendingPathComponent("graph-snapshot.json")
      guard let graphData = try? Data(contentsOf: graphURL) else { return nil }
      guard let graph = try? JSONDecoder().decode(LoopGraph.self, from: graphData) else {
        return nil
      }

      return GraphExportBundle(
        manifest: manifest,
        graphSnapshot: graph,
        memoryByNodeID: readMemory(in: tmpDir),
        sessionsByNodeID: readSessions(in: tmpDir)
      )
    } catch {
      return nil
    }
  }

  private static func readMemory(in tmpDir: URL) -> [String: [String]] {
    var memoryByNodeID: [String: [String]] = [:]
    let memoryDir = tmpDir.appendingPathComponent("memory")
    guard
      let nodeIDs = try? FileManager.default.contentsOfDirectory(atPath: memoryDir.path)
    else { return memoryByNodeID }
    for nodeID in nodeIDs {
      let logURL = memoryDir.appendingPathComponent(nodeID).appendingPathComponent(
        NodeMemory.logFileName)
      if let logContent = try? String(contentsOf: logURL, encoding: .utf8) {
        memoryByNodeID[nodeID] = logContent.split(whereSeparator: \.isNewline).map(String.init)
      }
    }
    return memoryByNodeID
  }

  private static func readSessions(in tmpDir: URL) -> [String: SessionTransplant.Artifact] {
    var sessionsByNodeID: [String: SessionTransplant.Artifact] = [:]
    let sessionsDir = tmpDir.appendingPathComponent("sessions")
    guard
      let nodeIDs = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
    else { return sessionsByNodeID }
    for nodeID in nodeIDs {
      let nodeDir = sessionsDir.appendingPathComponent(nodeID)
      guard let metaData = try? Data(contentsOf: nodeDir.appendingPathComponent("meta.json")),
        let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
        let backend = meta["backend"].flatMap(CLISessionBackendKind.init(rawValue:)),
        let sessionID = meta["sessionID"]
      else { continue }
      let files = filesUnder(nodeDir.appendingPathComponent("files"))
      guard !files.isEmpty else { continue }
      sessionsByNodeID[nodeID] = SessionTransplant.Artifact(
        backend: backend, sessionID: sessionID,
        sourceWorkingDirectory: meta["sourceWorkingDirectory"], files: files)
    }
    return sessionsByNodeID
  }

  private static func filesUnder(_ root: URL) -> [String: Data] {
    // Both sides resolved before the prefix strip: the staging dir lives under
    // `/var/folders`, the enumerator hands back `/private/var/folders`, and an
    // unresolved mismatch turned every relative key into an absolute path — which
    // `restore`'s `files["transcript.jsonl"]` lookup then missed.
    let rootPrefix = root.resolvingSymlinksInPath().path + "/"
    var files: [String: Data] = [:]
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return files }
    for case let url as URL in enumerator {
      guard
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
        let data = try? Data(contentsOf: url)
      else { continue }
      let resolved = url.resolvingSymlinksInPath().path
      guard resolved.hasPrefix(rootPrefix) else { continue }
      files[String(resolved.dropFirst(rootPrefix.count))] = data
    }
    return files
  }

  // MARK: - ZIP Helpers

  /// The manifest is the bundle's human-inspectable header, so dates ride as ISO-8601
  /// strings rather than Foundation's reference-date doubles — `2026-08-14T02:31:35Z`
  /// in a text editor instead of `808367495.09`. The graph snapshot keeps the default
  /// encoding: it round-trips through these same coders only, and matching the
  /// daemon's own persistence format costs nothing.
  private static func manifestEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func manifestDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func createZipArchive(at destination: URL, from source: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    // `--norsrc`, not `--sequesterRsrc`: sequestering writes AppleDouble copies into a
    // `__MACOSX/` shadow tree, which doubled the archive's file count with junk every
    // other platform shows the user. Nothing in a bundle has resource forks worth
    // keeping.
    process.arguments = ["-c", "-k", "--norsrc", source.path, destination.path]

    try? FileManager.default.removeItem(at: destination)
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
      "- **sessions/** — Each loop's backend conversation, where its CLI can carry one",
      "",
      "## How to Import",
      "",
      "In the GraphCode app: right-click any loop card (or the canvas) and choose",
      "Import Loops…, then pick this zip. Or from the shell:",
      "",
      "```bash",
      "graphcode node import /path/to/target/project /path/to/this/export.zip",
      "```",
      "",
      "Or import as children of an existing loop:",
      "",
      "```bash",
      "graphcode node import /path/to/target/project /path/to/this/export.zip \\",
      "  --as-child-of <parent-node-id>",
      "```",
      "",
      "## What Gets Imported",
      "",
      "- Node configuration (type, prompts, goals, backend, model tier)",
      "- Graph edges and connections (with UUID remapping to avoid collisions)",
      "- Session memory logs (history of what each node has done)",
      "- The backend conversation itself, per what each CLI supports:",
      "  - **Claude Code**: full transplant — the imported loop resumes the",
      "    exported conversation the first time it opens",
      "  - **Copilot**: session state transplanted for `--resume`; if the target's",
      "    Copilot refuses it, the loop starts fresh",
      "  - **Codex**: no resume support in the CLI — the rollout rides along as",
      "    readable history and the loop starts fresh",
      "- All sub-nodes if composite nodes are included",
      "",
      "## What's Fresh on Import",
      "",
      "- **Node IDs** are remapped to fresh UUIDs",
      "- **Session IDs** are rewritten to fresh ones (the conversation content survives)",
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
