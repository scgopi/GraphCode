import Foundation

/// Reads/writes the on-disk state Phase 4 adds: one JSON file per project's `LoopGraph`
/// plus a small recent-projects index, both under `~/Library/Application
/// Support/graphcode/` — never inside the project folder itself, so opening a folder in
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
    return try? JSONDecoder().decode(LoopGraph.self, from: data)
  }

  public func saveGraph(_ graph: LoopGraph) {
    guard let data = try? JSONEncoder().encode(graph) else { return }
    try? data.write(to: fileURL(forProjectPath: graph.project.path), options: .atomic)
  }

  /// Throws away a project's loops for good — the "Delete Loops…" half of the sidebar's
  /// context menu, which is why it's separate from `forgetProject`. Only ever touches
  /// graphcode's own file under Application Support; the project folder itself is never
  /// written to, deleted from, or otherwise modified.
  public func deleteGraph(path: String) {
    try? FileManager.default.removeItem(at: fileURL(forProjectPath: path))
  }

  /// Filenames are the canonical path with `/` replaced by `_` — simple, deterministic,
  /// and legible in a Finder window, which matters more here than collision-resistance
  /// does for a single-user local tool.
  private func fileURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName).json")
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
