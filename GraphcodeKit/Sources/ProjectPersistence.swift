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

  public init(baseDirectory: URL) {
    projectsDirectory = baseDirectory.appendingPathComponent("projects", isDirectory: true)
    recentProjectsFile = baseDirectory.appendingPathComponent("recent-projects.json")
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
    guard let data = try? JSONEncoder().encode(projects) else { return }
    try? data.write(to: recentProjectsFile, options: .atomic)
  }
}
