import Foundation

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
  private let platformPaths: any PlatformPaths

  public init(baseDirectory: URL) {
    self.init(baseDirectory: baseDirectory, platformPaths: CurrentPlatformPaths.value)
  }

  public init(baseDirectory: URL, platformPaths: any PlatformPaths) {
    projectsDirectory = baseDirectory.appendingPathComponent("projects", isDirectory: true)
    recentProjectsFile = baseDirectory.appendingPathComponent("recent-projects.json")
    openProjectsFile = baseDirectory.appendingPathComponent("open-projects.json")
    self.platformPaths = platformPaths
    try? FileManager.default.createDirectory(
      at: projectsDirectory, withIntermediateDirectories: true)
  }

  // MARK: - Per-project graph

  public func loadGraph(path: String) -> LoopGraph? {
    let currentURL = fileURL(forProjectPath: path)
    if let graph = decodeGraph(at: currentURL) {
      return graph
    }

    // Before v1 keys, macOS used the path itself as the filename. Keep this fallback
    // one-way: a successful read immediately moves the bytes to the safe filename so
    // future launches no longer depend on the legacy spelling.
    let legacyURL = legacyFileURL(forProjectPath: path)
    guard let legacyData = try? Data(contentsOf: legacyURL),
      let legacyGraph = try? JSONDecoder().decode(LoopGraph.self, from: legacyData),
      pathsMatch(legacyGraph.project.path, path)
    else { return nil }
    if (try? legacyData.write(to: currentURL, options: .atomic)) != nil {
      try? FileManager.default.removeItem(at: legacyURL)
    }
    return decodeGraph(data: legacyData)
  }

  private func decodeGraph(at url: URL) -> LoopGraph? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return decodeGraph(data: data)
  }

  private func decodeGraph(data: Data) -> LoopGraph? {
    guard var graph = try? JSONDecoder().decode(LoopGraph.self, from: data) else { return nil }
    for index in graph.nodes.indices {
      graph.nodes[index].presence = nil
      graph.nodes[index].activity = nil
    }
    return graph
  }

  public func saveGraph(_ graph: LoopGraph) {
    guard let data = try? JSONEncoder().encode(graph) else { return }
    let currentURL = fileURL(forProjectPath: graph.project.path)
    guard (try? data.write(to: currentURL, options: .atomic)) != nil else { return }
    removeLegacyGraphIfMatching(path: graph.project.path)
  }

  /// Throws away a project's loops for good — the "Delete Loops…" half of the sidebar's
  /// context menu, which is why it's separate from `forgetProject`. Only ever touches
  /// graphcode's own file under `~/.graphcode`; the project folder itself is never
  /// written to, deleted from, or otherwise modified.
  public func deleteGraph(path: String) {
    try? FileManager.default.removeItem(at: fileURL(forProjectPath: path))
    removeLegacyGraphIfMatching(path: path)
  }

  /// Filenames are versioned hashes of the canonical project path. A path-derived filename
  /// must be deterministic across launches, but Windows also rejects `:`, `\`, and several
  /// other characters that occur in perfectly valid project paths. Hashing keeps names
  /// short, safe, and collision-resistant without leaking a path into a directory listing.
  private func fileURL(forProjectPath path: String) -> URL {
    let key = platformPaths.persistenceKey(forProjectPath: path)
    return projectsDirectory.appendingPathComponent("\(key).json")
  }

  private func legacyFileURL(forProjectPath path: String) -> URL {
    let safeName = path.replacingOccurrences(of: "/", with: "_")
    return projectsDirectory.appendingPathComponent("\(safeName).json")
  }

  private func removeLegacyGraphIfMatching(path: String) {
    let legacyURL = legacyFileURL(forProjectPath: path)
    guard let graph = decodeGraph(at: legacyURL),
      pathsMatch(graph.project.path, path)
    else { return }
    try? FileManager.default.removeItem(at: legacyURL)
  }

  private func pathsMatch(_ storedPath: String, _ requestedPath: String) -> Bool {
    if storedPath == requestedPath { return true }
    guard let storedCanonical = try? platformPaths.canonicalProjectPath(storedPath),
      let requestedCanonical = try? platformPaths.canonicalProjectPath(requestedPath)
    else { return false }
    return storedCanonical == requestedCanonical
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
