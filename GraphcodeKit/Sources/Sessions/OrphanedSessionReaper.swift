import Foundation

/// `graphcode reap` — kills `zmx` sessions no graph node owns anymore (#197).
///
/// The on-demand recovery for a machine already out of PTYs: sessions leaked by deletes
/// that predate the condemned-list bookkeeping (`CondemnedSessions`) are in nobody's
/// records, so the only way to find them is to enumerate what `zmx` is holding and
/// subtract everything still owned.
///
/// "Owned" is computed the wide way, because the session namespace is machine-wide while
/// every other record is narrower: node ids from every project graph of *every*
/// workspace (sub-graph workers included), the app's quick chats, and every persisted
/// terminal layout — a session whose surface lives in a workspace this process was not
/// launched for is not an orphan. Two further rails: only names shaped
/// `graphcode-<uuid>` are considered at all, and a session with a client attached is
/// someone's open terminal, never reaped.
public enum OrphanedSessionReaper {
  public struct Candidate: Equatable, Sendable {
    public let name: String
    public let id: UUID
    public let clients: Int
  }

  public struct Report: Sendable {
    public var orphans: [String] = []
    public var reaped: [String] = []
    public var survived: [String] = []
    public var aborted: String?

    public init() {}
  }

  /// One row of `zmx ls` per session, as `key=value` tokens — the arrow zmx puts on the
  /// caller's own row and any token without `=` are skipped rather than tripped over.
  static func candidates(fromZmxList output: String) -> [Candidate] {
    output.split(separator: "\n").compactMap { line in
      var name: String?
      var clients: Int?
      var hasError = false
      for token in line.split(whereSeparator: \.isWhitespace) {
        if token.hasPrefix("name=") { name = String(token.dropFirst("name=".count)) }
        if token.hasPrefix("clients=") { clients = Int(token.dropFirst("clients=".count)) }
        if token.hasPrefix("err=") { hasError = true }
      }
      guard !hasError, let clients, let name, name.hasPrefix("graphcode-"),
        let id = UUID(uuidString: String(name.dropFirst("graphcode-".count)))
      else { return nil }
      return Candidate(name: name, id: id, clients: clients)
    }
  }

  static func orphans(among candidates: [Candidate], live: Set<UUID>) -> [Candidate] {
    candidates.filter { $0.clients == 0 && !live.contains($0.id) }
  }

  /// Every session id something on this machine still points at, or `nil` when a graph
  /// or terminal layout refused to decode. `nil` rather than skipping the file: state
  /// this build cannot read still owns its sessions, and a reap that cannot see them
  /// would kill them. Refusing to guess is the whole difference between a reap and a
  /// sweep.
  static func liveSessionIDs(
    workspaceDirectories: [URL] = workspaceDirectoriesForReap()
  ) -> Set<UUID>? {
    var live: Set<UUID> = []
    for directory in workspaceDirectories {
      var workspaceLive: Set<UUID> = []
      let projects = directory.appendingPathComponent("projects", isDirectory: true)
      let graphFiles =
        (try? FileManager.default.contentsOfDirectory(
          at: projects, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" } ?? []
      for file in graphFiles {
        guard let data = try? Data(contentsOf: file),
          let graph = try? JSONDecoder().decode(LoopGraph.self, from: data)
        else { return nil }
        workspaceLive.formUnion(graph.nodesAtAnyDepth.map(\.id))
      }
      workspaceLive.formUnion(QuickChatStore(baseDirectory: directory).load().map(\.id))

      let layouts = directory.appendingPathComponent("terminal-layouts", isDirectory: true)
      let layoutFiles =
        (try? FileManager.default.contentsOfDirectory(
          at: layouts, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "json" } ?? []
      for file in layoutFiles {
        guard let ownerID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
          workspaceLive.contains(ownerID)
        else { continue }
        guard let data = try? Data(contentsOf: file),
          let layout = try? JSONDecoder().decode(TerminalLayout.self, from: data)
        else { return nil }
        workspaceLive.formUnion(layout.tabs.flatMap(\.surfaces).map(\.id))
      }
      live.formUnion(workspaceLive)
    }
    return live
  }

  /// `Workspace.all()` discovers the default and named `.graphcode-*` directories. A
  /// development instance can instead point `GRAPHCODE_SUPPORT_DIR` at an arbitrary
  /// directory such as `.graphcode.dev`; include the directory this process actually
  /// uses as well, without scanning unrelated dot-directories in the home folder.
  static func workspaceDirectoriesForReap(
    discovered: [URL] = Workspace.all().map(\.url),
    current: URL = SupportDirectory.url
  ) -> [URL] {
    var seen = Set<String>()
    return (discovered + [current]).filter {
      seen.insert($0.standardizedFileURL.path).inserted
    }
  }

  public static func reap(dryRun: Bool) async -> Report {
    var report = Report()
    guard ZmxLocator.isInstalled else {
      report.aborted = "zmx is not installed"
      return report
    }
    guard let listing = await zmxList() else {
      report.aborted = "could not list zmx sessions"
      return report
    }
    guard let live = liveSessionIDs() else {
      report.aborted =
        "a graph or terminal layout failed to decode — refusing to guess which sessions it owns"
      return report
    }
    let found = orphans(among: candidates(fromZmxList: listing), live: live)
    report.orphans = found.map(\.name)
    guard !dryRun else { return report }
    for orphan in found {
      if await ZmxSessionLauncher.killConfirmingDeath(sessionNamed: orphan.name) {
        report.reaped.append(orphan.name)
      } else {
        report.survived.append(orphan.name)
      }
    }
    return report
  }

  /// A plain pipe rather than a PTY, same as `ZmxSessionLauncher.sessionScrollback`:
  /// the listing is a one-shot dump, and a pipe adds no terminal dressing to parse
  /// around.
  private static func zmxList() async -> String? {
    let process = Process()
    process.executableURL = ZmxLocator.binaryURL
    process.arguments = ["ls"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
