import Foundation
import GraphcodeKit
import Testing

/// Phase 4 (docs/07-roadmap.md#phase-4--projects): each project's graph is now
/// persisted under Application Support, keyed by folder path. Exercised against a
/// throwaway temp directory per test, never the app's real Application Support folder.
@Suite
struct ProjectPersistenceTests {
  private func makePersistence() -> ProjectPersistence {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return ProjectPersistence(baseDirectory: directory)
  }

  @Test
  func savingAndLoadingAGraphRoundTrips() {
    let persistence = makePersistence()
    let project = ProjectRef(path: "/tmp/my-project", name: "my-project")
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let graph = LoopGraph(project: project, nodes: [node])

    #expect(persistence.loadGraph(path: project.path) == nil)

    persistence.saveGraph(graph)
    let loaded = persistence.loadGraph(path: project.path)
    #expect(loaded?.nodes.count == 1)
    #expect(loaded?.project.path == project.path)
  }

  @Test
  func openProjectsAreTrackedSeparatelyFromRecents() {
    // The two lists answer different questions — "what was the sidebar showing" versus
    // "what has ever been opened" — which is what lets Close and Remove differ.
    let persistence = makePersistence()
    persistence.recordOpened(ProjectRef(path: "/tmp/a", name: "a"))
    persistence.recordOpened(ProjectRef(path: "/tmp/b", name: "b"))
    persistence.saveOpenProjects(["/tmp/a", "/tmp/b"])

    persistence.saveOpenProjects(["/tmp/a"])

    #expect(persistence.loadOpenProjects() == ["/tmp/a"])
    #expect(persistence.loadRecentProjects().count == 2)
  }

  @Test
  func forgettingAProjectLeavesItsGraphOnDisk() {
    let persistence = makePersistence()
    persistence.recordOpened(ProjectRef(path: "/tmp/a", name: "a"))
    persistence.saveGraph(
      LoopGraph(
        project: ProjectRef(path: "/tmp/a", name: "a"),
        nodes: [LoopNode(title: "Research", checkDescription: "Sound?")]))

    persistence.forgetProject(path: "/tmp/a")
    #expect(persistence.loadRecentProjects().isEmpty)
    #expect(persistence.loadGraph(path: "/tmp/a")?.nodes.count == 1)

    persistence.deleteGraph(path: "/tmp/a")
    #expect(persistence.loadGraph(path: "/tmp/a") == nil)
  }

  @Test
  func recordingAnOpenedProjectDeduplicatesByPath() {
    let persistence = makePersistence()
    let project = ProjectRef(path: "/tmp/my-project", name: "my-project", lastOpenedAt: Date())

    persistence.recordOpened(project)
    persistence.recordOpened(
      ProjectRef(
        path: project.path, name: project.name, lastOpenedAt: Date().addingTimeInterval(10)))

    #expect(persistence.loadRecentProjects().count == 1)
  }

  @Test
  func stalePresenceIsStrippedOnLoad() {
    let persistence = makePersistence()
    let project = ProjectRef(path: "/tmp/presence-test", name: "presence-test")
    var node = LoopNode(
      title: "Worker",
      loopType: .goalBased,
      goal: GoalSpec(summary: "ship it"),
      presence: PresenceReading(presence: .busy, confidence: .reported),
      state: .running)
    node.activity = "editing Foo.swift"
    let graph = LoopGraph(project: project, nodes: [node])

    persistence.saveGraph(graph)
    let loaded = persistence.loadGraph(path: project.path)

    #expect(loaded?.nodes.first?.presence == nil)
    #expect(loaded?.nodes.first?.activity == nil)
    #expect(loaded?.nodes.first?.state == .running)
  }

  @Test
  func recentProjectsAreSortedMostRecentlyOpenedFirst() {
    let persistence = makePersistence()
    let older = ProjectRef(path: "/tmp/older", name: "older", lastOpenedAt: Date())
    let newer = ProjectRef(
      path: "/tmp/newer", name: "newer", lastOpenedAt: Date().addingTimeInterval(60))

    persistence.recordOpened(older)
    persistence.recordOpened(newer)

    let recents = persistence.loadRecentProjects()
    #expect(recents.map(\.path) == [newer.path, older.path])
    #expect(recents.map(\.path) == [newer.path, older.path])
  }
  @Test
  func loadingALegacyPathDerivedGraphMigratesItToTheSafeKey() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let persistence = ProjectPersistence(baseDirectory: directory)
    let project = ProjectRef(path: "/tmp/legacy-project", name: "legacy-project")
    let graph = LoopGraph(project: project, nodes: [LoopNode(title: "Legacy")])
    let legacyURL = directory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("_tmp_legacy-project.json")
    try JSONEncoder().encode(graph).write(to: legacyURL)

    #expect(persistence.loadGraph(path: project.path)?.nodes.first?.title == "Legacy")
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))

    let files = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("projects", isDirectory: true),
      includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(files.first?.lastPathComponent.hasPrefix("v1-") == true)
  }

  @Test
  func deletingAGraphAlsoRemovesItsLegacyPathDerivedFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let persistence = ProjectPersistence(baseDirectory: directory)
    let path = "/tmp/legacy-delete"
    let legacyURL = directory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("_tmp_legacy-delete.json")
    let graph = LoopGraph(project: ProjectRef(path: path, name: "legacy-delete"))
    try JSONEncoder().encode(graph).write(to: legacyURL)

    persistence.deleteGraph(path: path)

    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(persistence.loadGraph(path: path) == nil)
  }
}
