import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// One GraphCode-owned Goobers instance, persistent for the life of a graph.
///
/// The graph UUID is the directory identity: project names and paths can change, while
/// the graph's identity does not. No existing Goobers instance is imported or edited.
public struct GoobersWorkspace: Sendable {
  public enum WorkspaceError: Error, Equatable, Sendable {
    case remoteProjectUnsupported
    case noGitOrigin
    case unsupportedOrigin(String)
    case commandFailed(String)
    case executableNotFound
    case daemonExited(String)
    case daemonTimedOut
    case triggerReturnedNoRun
    case unsafeExportPath(String)
  }

  public struct Prepared: Equatable, Sendable {
    public var root: URL
    public var snapshotID: String
    public var gaggle: String
    public var workflow: String
  }

  public struct Dispatch: Equatable, Sendable {
    public var runID: String
    public var snapshotID: String
  }

  public let graphID: UUID
  public let baseDirectory: URL

  public init(graphID: UUID, baseDirectory: URL = SupportDirectory.url) {
    self.graphID = graphID
    self.baseDirectory = baseDirectory
  }

  public var root: URL {
    baseDirectory
      .appendingPathComponent("goobers", isDirectory: true)
      .appendingPathComponent(graphID.uuidString.lowercased(), isDirectory: true)
  }

  public func prepare(_ graph: LoopGraph) throws -> Prepared {
    guard RemoteProjectLocation.parse(projectPath: graph.project.path) == nil else {
      throw WorkspaceError.remoteProjectUnsupported
    }
    let project = try Self.projectCoordinates(at: graph.project.path)
    let gaggle = "graphcode"
    let workflow = GoobersExport.slug(graph.project.name)
    let bundle = try GoobersExport.export(
      graph: graph, workflowName: workflow, gaggleName: gaggle, project: project)
    let snapshotID = UUID().uuidString.lowercased()

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try GoobersExport.runtimeInstance(project: project)
      .write(
        to: root.appendingPathComponent("instance.yaml"),
        atomically: true,
        encoding: .utf8)

    let staging = root.appendingPathComponent(".config-\(snapshotID)", isDirectory: true)
    try writeConfig(bundle, to: staging)
    try replaceConfig(with: staging)

    let snapshot =
      root
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(snapshotID, isDirectory: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try writeConfig(bundle, to: snapshot.appendingPathComponent("config", isDirectory: true))
    try GoobersExport.runtimeInstance(project: project)
      .write(
        to: snapshot.appendingPathComponent("instance.yaml"),
        atomically: true,
        encoding: .utf8)

    return Prepared(root: root, snapshotID: snapshotID, gaggle: gaggle, workflow: workflow)
  }

  public func dispatch(
    _ graph: LoopGraph,
    executable: URL? = nil
  ) async throws -> Dispatch {
    let prepared = try prepare(graph)
    // `--watch-config` reloads asynchronously. Triggering immediately after the atomic
    // directory swap can therefore mint a run against the previous definition — a race
    // observed on the first end-to-end smoke run. Each graph owns this daemon and runs
    // at maxParallelRuns=1, so restart it at the explicit dispatch boundary: startup
    // loads the exact snapshot above before the trigger plane becomes ready.
    await stopDaemon()
    let client = try await ensureDaemon(executable: executable)
    let requestID = "graphcode-\(graph.id.uuidString)-\(prepared.snapshotID)"
    let response = try await client.trigger(
      gaggle: prepared.gaggle, workflow: prepared.workflow, requestID: requestID)
    guard let runID = response.runId, !runID.isEmpty else {
      throw WorkspaceError.triggerReturnedNoRun
    }
    try record(runID: runID, prepared: prepared)
    return Dispatch(runID: runID, snapshotID: prepared.snapshotID)
  }

  public func ensureDaemon(executable: URL? = nil) async throws -> GoobersClient {
    let client = GoobersClient(instanceRoot: root)
    if let health = try? await client.health(), health.ready { return client }

    let binary = try executable ?? Self.findExecutable()
    try? FileManager.default.removeItem(at: client.addressFile)
    let log = root.appendingPathComponent("graphcode-goobers.log")
    if !FileManager.default.fileExists(atPath: log.path) {
      FileManager.default.createFile(atPath: log.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: log)
    try handle.seekToEnd()

    let process = Process()
    process.executableURL = binary
    process.arguments = [
      "up", "--watch-config", "--skip-preflight", "--drain-timeout", "3s", root.path,
    ]
    process.currentDirectoryURL = root
    process.standardOutput = handle
    process.standardError = handle
    try process.run()

    for _ in 0..<200 {
      if let health = try? await client.health(), health.ready {
        try? handle.close()
        return client
      }
      if !process.isRunning {
        try? handle.close()
        throw WorkspaceError.daemonExited(Self.logTail(at: log))
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    process.terminate()
    try? handle.close()
    throw WorkspaceError.daemonTimedOut
  }

  public func remove() async throws {
    await stopDaemon()
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  }

  public func stopDaemon() async {
    if let owner = try? daemonOwner(), owner.instanceRoot == root.path {
      _ = kill(owner.pid, SIGTERM)
      for _ in 0..<50 where kill(owner.pid, 0) == 0 {
        try? await Task.sleep(for: .milliseconds(100))
      }
      if kill(owner.pid, 0) == 0 { _ = kill(owner.pid, SIGKILL) }
    }
  }

  static func projectCoordinates(at path: String) throws -> GoobersExport.ProjectCoordinates {
    let origin = try command(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["git", "-C", path, "remote", "get-url", "origin"]
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !origin.isEmpty else { throw WorkspaceError.noGitOrigin }
    guard let coordinates = parseGitHubOrigin(origin) else {
      throw WorkspaceError.unsupportedOrigin(origin)
    }
    let branch = runnableBranch(at: path)
    return GoobersExport.ProjectCoordinates(
      owner: coordinates.owner, name: coordinates.name, branch: branch)
  }

  /// Goobers creates a fresh managed clone, so an unpushed local branch is not a valid
  /// base even when it is the branch GraphCode itself was built from. Preserve the
  /// current branch when the fetched origin has it; otherwise use origin's advertised
  /// default. Hosted execution can later accept an explicit ref or patch.
  static func runnableBranch(at path: String) -> String {
    let executable = URL(fileURLWithPath: "/usr/bin/env")
    if let current =
      try? command(
        executable: executable,
        arguments: ["git", "-C", path, "branch", "--show-current"]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !current.isEmpty,
      (try? command(
        executable: executable,
        arguments: [
          "git", "-C", path, "rev-parse", "--verify", "--quiet",
          "refs/remotes/origin/\(current)",
        ])) != nil
    {
      return current
    }
    if let remoteHead =
      try? command(
        executable: executable,
        arguments: ["git", "-C", path, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines),
      remoteHead.hasPrefix("origin/")
    {
      return String(remoteHead.dropFirst("origin/".count))
    }
    if (try? command(
      executable: executable,
      arguments: [
        "git", "-C", path, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main",
      ])) != nil
    {
      return "main"
    }
    return "master"
  }

  static func parseGitHubOrigin(_ origin: String) -> (owner: String, name: String)? {
    var path: String
    if origin.hasPrefix("git@github.com:") {
      path = String(origin.dropFirst("git@github.com:".count))
    } else if let url = URL(string: origin), url.host?.lowercased() == "github.com" {
      path = url.path
    } else {
      return nil
    }
    path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.hasSuffix(".git") { path.removeLast(4) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]))
  }

  static func findExecutable() throws -> URL {
    var candidates = [
      SupportDirectory.url.appendingPathComponent("bin/goobers"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/goobers"),
      URL(fileURLWithPath: "/opt/homebrew/bin/goobers"),
      URL(fileURLWithPath: "/usr/local/bin/goobers"),
    ]
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      candidates += path.split(separator: ":").map {
        URL(fileURLWithPath: String($0)).appendingPathComponent("goobers")
      }
    }
    guard
      let found = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw WorkspaceError.executableNotFound
    }
    return found
  }

  private func writeConfig(_ bundle: GoobersExport.Bundle, to directory: URL) throws {
    for (path, contents) in bundle.files where path != "instance.yaml.example" {
      let components = path.split(separator: "/")
      guard !path.hasPrefix("/"), !components.contains("..") else {
        throw WorkspaceError.unsafeExportPath(path)
      }
      let destination = components.reduce(directory) {
        $0.appendingPathComponent(String($1))
      }
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: destination, atomically: true, encoding: .utf8)
    }
  }

  private func replaceConfig(with staging: URL) throws {
    let current = root.appendingPathComponent("config", isDirectory: true)
    let previous = root.appendingPathComponent(".config-previous", isDirectory: true)
    try? FileManager.default.removeItem(at: previous)
    if FileManager.default.fileExists(atPath: current.path) {
      try FileManager.default.moveItem(at: current, to: previous)
    }
    do {
      try FileManager.default.moveItem(at: staging, to: current)
      try? FileManager.default.removeItem(at: previous)
    } catch {
      if FileManager.default.fileExists(atPath: previous.path) {
        try? FileManager.default.moveItem(at: previous, to: current)
      }
      throw error
    }
  }

  private func record(runID: String, prepared: Prepared) throws {
    struct Record: Codable {
      var runID: String
      var snapshotID: String
      var startedAt: Date
    }
    let directory = root.appendingPathComponent("graphcode-runs", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(
      Record(runID: runID, snapshotID: prepared.snapshotID, startedAt: Date()))
    try data.write(
      to: directory.appendingPathComponent("\(runID).json"), options: .atomic)
  }

  private func daemonOwner() throws -> DaemonOwner {
    let data = try Data(
      contentsOf: root.appendingPathComponent("scheduler/up.lock"))
    return try JSONDecoder().decode(DaemonOwner.self, from: data)
  }

  private struct DaemonOwner: Decodable {
    var pid: Int32
    var instanceRoot: String
  }

  private static func command(
    executable: URL, arguments: [String]
  ) throws -> String {
    let output = Pipe()
    let error = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      let stderr = error.fileHandleForReading.readDataToEndOfFile()
      let message = String(decoding: stderr, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw WorkspaceError.commandFailed(message)
    }
    return String(decoding: stdout, as: UTF8.self)
  }

  private static func logTail(at url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "Goobers exited during startup." }
    return String(decoding: data.suffix(8_192), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension GoobersWorkspace.WorkspaceError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .remoteProjectUnsupported:
      return "Hosted Goobers execution is not enabled yet; this graph points at a remote project."
    case .noGitOrigin:
      return "This project has no Git origin for Goobers to clone."
    case .unsupportedOrigin(let origin):
      return "Goobers export currently supports github.com origins, not \(origin)."
    case .commandFailed(let message):
      return message.isEmpty ? "A required command failed." : message
    case .executableNotFound:
      return "No Goobers executable was found in GraphCode's bin directory or PATH."
    case .daemonExited(let message):
      return "The Goobers daemon exited during startup: \(message)"
    case .daemonTimedOut:
      return "The Goobers daemon did not become ready in 20 seconds."
    case .triggerReturnedNoRun:
      return "Goobers accepted the trigger but did not return a run ID."
    case .unsafeExportPath(let path):
      return "The Goobers export contained an unsafe path: \(path)"
    }
  }
}
