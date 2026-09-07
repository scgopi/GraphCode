import Foundation
import MailroomKit

/// Reads/writes the on-disk state Phase 4 adds: one JSON file per project's `LoopGraph`
/// plus small recents and open-projects indexes, all under `~/.graphcode` (see
/// `SupportDirectory`) — never inside the project folder itself, so opening a folder in
/// graphcode never touches that folder's own contents (confirmed with the user before
/// building this; see docs/07-roadmap.md#phase-4--projects).
///
/// A plain `Sendable` struct, not an actor: these are small local JSON files and every
/// call site (`ProjectRegistry`) is already actor-isolated, so there's nothing here
/// that needs its own isolation.
public struct ProjectPersistence: Sendable {
  private let projectsDirectory: URL
  private let recentProjectsFile: URL
  private let openProjectsFile: URL

  public init(baseDirectory: URL) {
    projectsDirectory = baseDirectory.appendingPathComponent("projects", isDirectory: true)
    recentProjectsFile = baseDirectory.appendingPathComponent("recent-projects.json")
    openProjectsFile = baseDirectory.appendingPathComponent("open-projects.json")
    try? FileManager.default.createDirectory(
      at: projectsDirectory, withIntermediateDirectories: true)
  }

  // MARK: - Per-project graph

  public func loadGraph(path: String) -> LoopGraph? {
    guard let data = try? Data(contentsOf: fileURL(forProjectPath: path)) else { return nil }
    guard var graph = try? JSONDecoder().decode(LoopGraph.self, from: data) else { return nil }
    for index in graph.nodes.indices {
      graph.nodes[index].presence = nil
      graph.nodes[index].activity = nil
    }
    // The room's own file wins over one still inline in the graph file — a graph saved
    // before the split carries its posts inline, and decodes exactly as it always did.
    if let room = try? Data(contentsOf: mailroomURL(forProjectPath: path)),
      let posts = try? JSONDecoder().decode([MailroomPost].self, from: room)
    {
      graph.mailroom = posts
    }
    return graph
  }

  /// Two files: the graph without its room, rewritten on every change, and the room on
  /// its own, rewritten only when the room changed. The room was 84% of the graph file
  /// (271 KB of 323 KB on the graph that filed #307) and changes only when a post lands,
  /// while the graph changes on every memo, state tick and cursor move — the same
  /// argument #293 made for the wire, applied to the file.
  public func saveGraph(_ graph: LoopGraph) {
    var slim = graph
    slim.mailroom = []
    guard let data = try? JSONEncoder().encode(slim) else { return }
    do {
      try data.write(to: fileURL(forProjectPath: graph.project.path), options: .atomic)
    } catch {
      return
    }
    let roomURL = mailroomURL(forProjectPath: graph.project.path)
    let digest = MailroomDigest(of: graph.mailroom)
    guard !Self.roomDigests.matches(digest, for: roomURL.path)
      || !FileManager.default.fileExists(atPath: roomURL.path)
    else { return }
    if graph.mailroom.isEmpty {
      do {
        try FileManager.default.removeItem(at: roomURL)
      } catch where !FileManager.default.fileExists(atPath: roomURL.path) {
        Self.roomDigests.set(digest, for: roomURL.path)
      } catch {
        return
      }
    } else if let room = try? JSONEncoder().encode(graph.mailroom) {
      do {
        try room.write(to: roomURL, options: .atomic)
      } catch {
        return
      }
    } else {
      return
    }
    Self.roomDigests.set(digest, for: roomURL.path)
  }

  /// What the room last written for each project looked like, so an unchanged room is
  /// not rewritten. Process-wide because this type is a value: every copy writes the
  /// same files. A miss (first save after launch) writes once and is then remembered.
  ///
  /// Keyed by the room *file*, not the project path: one path is the same project in
  /// every workspace but a different file in each, and sharing an entry across them
  /// would judge a room unchanged against a digest taken from someone else's file and
  /// never write it.
  private static let roomDigests = RoomDigests()

  private final class RoomDigests: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [String: MailroomDigest] = [:]

    func matches(_ digest: MailroomDigest, for path: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return digests[path] == digest
    }

    func set(_ digest: MailroomDigest, for path: String) {
      lock.lock()
      digests[path] = digest
      lock.unlock()
    }

    func forget(_ path: String) {
      lock.lock()
      defer { lock.unlock() }
      digests.removeValue(forKey: path)
    }
  }

  /// Throws away a project's loops for good — the "Delete Loops…" half of the sidebar's
  /// context menu, which is why it's separate from `forgetProject`. Only ever touches
  /// graphcode's own file under `~/.graphcode`; the project folder itself is never
  /// written to, deleted from, or otherwise modified.
  public func deleteGraph(path: String) {
    try? FileManager.default.removeItem(at: fileURL(forProjectPath: path))
    try? FileManager.default.removeItem(at: mailroomURL(forProjectPath: path))
    // The digest cache is keyed by path and outlives the file. Left behind, a project
    // re-created at the same path whose room happens to match the deleted one would be
    // judged unchanged and never written.
    Self.roomDigests.forget(mailroomURL(forProjectPath: path).path)
  }

  /// Filenames are the canonical path with `/` replaced by `_` — simple, deterministic,
  /// and legible in a Finder window, which matters more here than collision-resistance
  /// does for a single-user local tool.
  private func fileURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName).json")
  }

  /// The room beside its graph: `<name>.mailroom.json`.
  private func mailroomURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName)\(Self.roomFileSuffix)")
  }

  /// Every suffix this type writes into `projects/` *beside* a graph rather than as one.
  ///
  /// `projects/` held nothing but graphs until #307 moved the room out of the graph file,
  /// so readers scanning it — `OrphanedSessionReaper`, `Workspace.contents` — took every
  /// `.json` in it for a graph. That assumption is now false, and it failed loudly in the
  /// worst place: `reap` treats an undecodable file as state it cannot account for and
  /// aborts, so a room file disabled the tool people reach for when they are out of PTYs.
  ///
  /// **Adding a sidecar means adding its suffix here**, in the same type that mints the
  /// name, so a reader never has to be taught about it separately. Anything not listed
  /// still fails closed, which is the safe direction but also a silently broken `reap`.
  static let roomFileSuffix = ".mailroom.json"
  static let sidecarFileSuffixes = [roomFileSuffix]

  /// Whether a file in `projects/` is a sidecar rather than a graph. Answered from the
  /// name alone and deliberately not from the contents: a *corrupt* sidecar is still a
  /// sidecar, and it never owned a session, so it must not be mistaken for a damaged
  /// graph and stop a reap.
  public static func isSidecarFileName(_ name: String) -> Bool {
    sidecarFileSuffixes.contains { name.hasSuffix($0) }
  }

  // MARK: - Recent projects

  public func loadRecentProjects() -> [ProjectRef] {
    guard let data = try? Data(contentsOf: recentProjectsFile) else { return [] }
    let projects = (try? JSONDecoder().decode([ProjectRef].self, from: data)) ?? []
    return projects.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
  }

  public func recordOpened(_ project: ProjectRef) {
    var projects = loadRecentProjects().filter { $0.path != project.path }
    projects.append(project)
    saveRecentProjects(projects)
  }

  /// Drops a project from the recents index — "Remove from Graphcode". Its saved graph
  /// stays on disk, so re-opening the same folder brings the loops back; wiping those is
  /// `deleteGraph(path:)`, a deliberately separate and separately-confirmed action.
  public func forgetProject(path: String) {
    saveRecentProjects(loadRecentProjects().filter { $0.path != path })
  }

  private func saveRecentProjects(_ projects: [ProjectRef]) {
    guard let data = try? JSONEncoder().encode(projects) else { return }
    try? data.write(to: recentProjectsFile, options: .atomic)
  }

  // MARK: - Open projects

  /// Which projects the sidebar was showing, as distinct from which have ever been
  /// opened. Keeping these separate is what lets "Close" and "Remove from Graphcode" mean
  /// different things: closing a project drops it from here but leaves it in recents, so
  /// it stays one click away under Add Folder.
  public func loadOpenProjects() -> [String] {
    guard let data = try? Data(contentsOf: openProjectsFile) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  public func saveOpenProjects(_ paths: [String]) {
    guard let data = try? JSONEncoder().encode(paths) else { return }
    try? data.write(to: openProjectsFile, options: .atomic)
  }
}
