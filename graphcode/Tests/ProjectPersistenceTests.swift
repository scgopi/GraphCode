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
  func recentProjectsAreSortedMostRecentlyOpenedFirst() {
    let persistence = makePersistence()
    let older = ProjectRef(path: "/tmp/older", name: "older", lastOpenedAt: Date())
    let newer = ProjectRef(
      path: "/tmp/newer", name: "newer", lastOpenedAt: Date().addingTimeInterval(60))

    persistence.recordOpened(older)
    persistence.recordOpened(newer)

    let recents = persistence.loadRecentProjects()
    #expect(recents.map(\.path) == [newer.path, older.path])
  }
}
