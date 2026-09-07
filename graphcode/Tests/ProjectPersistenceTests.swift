import Foundation
import GraphcodeKit
import MailroomKit
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
  }
}

/// Issue #307: the room lives in its own file beside the graph, rewritten only when it
/// changed, and the graph file — rewritten on every change — no longer carries a post.
@Suite
struct MailroomPersistenceTests {
  private func makeDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func post(_ id: Int, _ body: String) -> MailroomPost {
    MailroomPost(
      id: id, at: Date(timeIntervalSince1970: TimeInterval(id)), authorID: nil,
      author: "a human", topic: nil, body: body)
  }

  @Test
  func theRoomIsSavedBesideTheGraphAndNeverInsideIt() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(baseDirectory: directory)
    let path = "/tmp/room-\(UUID().uuidString.prefix(6))"
    var graph = LoopGraph(project: ProjectRef(path: path, name: "room"))
    graph.nodes.append(LoopNode(title: "Loop", loopType: .turnBased, firstInstruction: "Work"))
    graph.mailroom = [post(1, "SECRET-NONCE-A"), post(2, "SECRET-NONCE-B")]

    persistence.saveGraph(graph)
    let name = path.replacingOccurrences(of: "/", with: "_")
    let graphFile = directory.appendingPathComponent("projects/\(name).json")
    let roomFile = directory.appendingPathComponent("projects/\(name).mailroom.json")
    let graphText = try String(contentsOf: graphFile, encoding: .utf8)
    #expect(!graphText.contains("SECRET-NONCE"))
    #expect(!graphText.contains("\"mailroom\""))
    #expect(try String(contentsOf: roomFile, encoding: .utf8).contains("SECRET-NONCE-B"))

    let loaded = try #require(persistence.loadGraph(path: path))
    #expect(loaded.mailroom == graph.mailroom)
    #expect(loaded.nodes.map(\.title) == ["Loop"])

    // A change that leaves the room alone rewrites the graph file only.
    let roomStamp =
      try FileManager.default.attributesOfItem(atPath: roomFile.path)[
        .modificationDate] as? Date
    graph.nodes[0].title = "Renamed"
    Thread.sleep(forTimeInterval: 0.02)
    persistence.saveGraph(graph)
    let roomStampAfter =
      try FileManager.default.attributesOfItem(atPath: roomFile.path)[
        .modificationDate] as? Date
    #expect(roomStamp == roomStampAfter)
    #expect(try #require(persistence.loadGraph(path: path)).nodes[0].title == "Renamed")

    persistence.deleteGraph(path: path)
    #expect(!FileManager.default.fileExists(atPath: graphFile.path))
    #expect(!FileManager.default.fileExists(atPath: roomFile.path))
  }

  /// A graph file saved before the split carries its posts inline, and loads as it did.
  @Test
  func aGraphSavedWithTheRoomInlineStillLoadsIt() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(baseDirectory: directory)
    let path = "/tmp/legacy-\(UUID().uuidString.prefix(6))"
    var graph = LoopGraph(project: ProjectRef(path: path, name: "legacy"))
    graph.mailroom = [post(1, "from before the split")]
    let name = path.replacingOccurrences(of: "/", with: "_")
    try JSONEncoder().encode(graph).write(
      to: directory.appendingPathComponent("projects/\(name).json"))

    #expect(try #require(persistence.loadGraph(path: path)).mailroom == graph.mailroom)
  }

  /// A reader sees the newest snapshot whether or not it has reached the disk yet —
  /// what keeps a delete of a closed project from missing loops still queued.
  @Test
  func aLoadReturnsTheQueuedSnapshotBeforeTheDiskHasIt() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(baseDirectory: directory)
    let writer = GraphWriter(persistence: persistence)
    let path = "/tmp/queued-\(UUID().uuidString.prefix(6))"
    var graph = LoopGraph(project: ProjectRef(path: path, name: "queued"))
    graph.nodes.append(LoopNode(title: "One", loopType: .turnBased, firstInstruction: "Work"))
    writer.save(graph)
    writer.flush()
    graph.nodes.append(LoopNode(title: "Two", loopType: .turnBased, firstInstruction: "Work"))
    graph.nodes.append(LoopNode(title: "Three", loopType: .turnBased, firstInstruction: "Work"))
    // Queued but, as far as this test can force it, not yet written: the writer's own
    // answer must already be the three-loop graph either way.
    writer.save(graph)
    #expect(writer.load(path: path)?.nodes.count == 3)
    writer.flush()
    #expect(persistence.loadGraph(path: path)?.nodes.count == 3)
    #expect(writer.load(path: "/tmp/never-saved") == nil)
  }

  /// The writer takes a burst and lands the newest snapshot once; `flush` returns with
  /// it on disk.
  @Test
  func theWriterCoalescesABurstAndFlushLandsTheNewest() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(baseDirectory: directory)
    let writer = GraphWriter(persistence: persistence)
    let path = "/tmp/burst-\(UUID().uuidString.prefix(6))"
    var graph = LoopGraph(project: ProjectRef(path: path, name: "burst"))
    graph.nodes.append(LoopNode(title: "v0", loopType: .turnBased, firstInstruction: "Work"))
    for version in 1...50 {
      graph.nodes[0].title = "v\(version)"
      writer.save(graph)
    }
    writer.flush()
    #expect(try #require(persistence.loadGraph(path: path)).nodes[0].title == "v50")
  }
}
