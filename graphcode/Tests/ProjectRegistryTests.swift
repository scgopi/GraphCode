import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// Phase 4 (docs/07-roadmap.md#phase-4--projects): `ProjectRegistry` is the multi-graph
/// routing layer in front of `GraphStore` — these exercise its routing logic directly,
/// without a real socket (matching how `GraphStoreTests` tests `GraphStore` itself).
///
/// `ProjectRegistry` has no public accessor for a project's in-memory graph (by
/// design — the wire protocol is the only intended way to read it), so these observe
/// routing behavior through the one other side effect it has: what ends up persisted
/// on disk via `ProjectPersistence`.
@Suite
struct ProjectRegistryTests {
  /// The registry refuses a path that names no directory, so the folders these tests open
  /// have to be there. They were not, and the tests passed anyway — which is exactly how
  /// `/tmp/x` and a folder called "/" ended up as real projects with real stores.
  init() throws {
    for name in [
      "project-a", "project-b", "project-c", "project-d", "project-e", "project-f", "project-g",
      "project-h", "project-i",
    ] {
      try FileManager.default.createDirectory(
        atPath: "/tmp/\(name)", withIntermediateDirectories: true)
    }
  }

  private func makeRegistryAndPersistence() -> (ProjectRegistry, ProjectPersistence) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return (
      ProjectRegistry(persistenceDirectory: directory, persistsSynchronously: true),
      ProjectPersistence(baseDirectory: directory)
    )
  }

  @Test
  func openingTheSamePathTwiceRoutesBothConnectionsToOneSharedGraph() async {
    let (registry, persistence) = makeRegistryAndPersistence()

    let firstConnection = UUID()
    await registry.addConnection(id: firstConnection, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: firstConnection)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(
          NodeDraft(
            title: "Research", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: firstConnection)

    let secondConnection = UUID()
    await registry.addConnection(id: secondConnection, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: secondConnection)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(
          NodeDraft(
            title: "Implement", loopType: .turnBased, checkDescription: "Correct?",
            firstInstruction: "Work"))),
      connectionID: secondConnection)

    // If the two connections had landed on separate `GraphStore` instances, the second
    // connection's save would have overwritten the first's on disk with only one node.
    let persisted = persistence.loadGraph(path: "/tmp/project-a")
    #expect(persisted?.nodes.count == 2)
  }

  @Test
  func twoDifferentPathsGetIndependentGraphs() async {
    let (registry, persistence) = makeRegistryAndPersistence()

    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)

    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(
          NodeDraft(
            title: "Research", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: connectionID)

    await registry.handle(.openProject(path: "/tmp/project-b"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-b",
        command: .createNode(
          NodeDraft(
            title: "Design", loopType: .turnBased, checkDescription: "Clear?",
            firstInstruction: "Work"))),
      connectionID: connectionID)

    #expect(persistence.loadGraph(path: "/tmp/project-a")?.nodes.count == 1)
    #expect(persistence.loadGraph(path: "/tmp/project-b")?.nodes.count == 1)
    #expect(
      persistence.loadGraph(path: "/tmp/project-a")?.nodes.first?.title
        != persistence.loadGraph(path: "/tmp/project-b")?.nodes.first?.title)
  }

  @Test
  func aGraphCommandForAPathNeverOpenedIsANoOpNotACrash() async {
    let (registry, _) = makeRegistryAndPersistence()
    // No `.openProject` was ever sent for this path — this must not crash.
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/never-opened",
        command: .createNode(
          NodeDraft(
            title: "Research", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: UUID())
  }

  /// The bug this guards: `.openProject` used to detach a connection from whatever
  /// project it had previously joined before joining the new one, so opening a second
  /// folder silently stopped the first folder's `graphChanged` broadcasts from ever
  /// reaching the socket. The persisted-file side channel the other tests use can't
  /// observe that — a broadcast that never left the daemon still gets persisted, since
  /// persistence and broadcast are two independent things `GraphStore.broadcast` does.
  /// A real socket pair is the only way to see whether the *bytes* arrive.
  @Test
  func openingASecondProjectKeepsTheFirstProjectsBroadcastsFlowing() async throws {
    var fds: [Int32] = [0, 0]
    let pairResult = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    #expect(pairResult == 0)
    let (daemonEnd, testEnd) = (fds[0], fds[1])
    defer {
      close(daemonEnd)
      close(testEnd)
    }

    let (registry, _) = makeRegistryAndPersistence()
    let connectionID = UUID()

    async let driver: Void = {
      await registry.addConnection(id: connectionID, fileDescriptor: daemonEnd)
      await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connectionID)
      await registry.handle(.openProject(path: "/tmp/project-b"), connectionID: connectionID)
      await registry.handle(
        .graphCommand(
          projectPath: "/tmp/project-a",
          command: .createNode(
            NodeDraft(
              title: "Research", loopType: .turnBased, checkDescription: "Sound?",
              firstInstruction: "Work"))),
        connectionID: connectionID)
    }()

    // Three frames land on `testEnd`: the snapshot from joining project-a, the snapshot
    // from joining project-b, then the graphChanged from mutating project-a. Reads are
    // bridged off-thread (matching `readFrameAsync` in `graphcoded/Sources/main.swift`)
    // so a blocking `read(2)` never occupies a thread the concurrency runtime also needs
    // to run `driver` on.
    _ = try await readFrameOffThread(testEnd)
    _ = try await readFrameOffThread(testEnd)
    let data = try await readFrameOffThread(testEnd)
    let event = try JSONDecoder().decode(DaemonEvent.self, from: data)

    guard case .graphChanged(let graph) = event else {
      Issue.record("expected a graphChanged event, got \(event)")
      return
    }
    #expect(graph.project.path == "/tmp/project-a")
    #expect(graph.nodes.count == 1)

    await driver
  }

  @Test
  func openingAProjectRecordsItAsRecentlyOpened() async {
    let (registry, persistence) = makeRegistryAndPersistence()

    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-c"), connectionID: connectionID)

    #expect(persistence.loadRecentProjects().contains { $0.path == "/tmp/project-c" })
  }

  /// The bug this guards: the app relaunched with an empty sidebar because nothing ever
  /// reopened what was showing when it quit — the daemon had persisted it all along.
  @Test
  func restoringReopensExactlyWhatWasOpenAtQuit() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let firstRun = UUID()
    await registry.addConnection(id: firstRun, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: firstRun)
    await registry.handle(.openProject(path: "/tmp/project-b"), connectionID: firstRun)
    await registry.handle(.closeProject(path: "/tmp/project-b"), connectionID: firstRun)

    // A closed project stays in recents — that's what makes Close reversible from the
    // Add Folder menu — but must not come back in the sidebar.
    #expect(Self.names(persistence.loadOpenProjects()) == ["project-a"])
    #expect(persistence.loadRecentProjects().count == 2)

    // Second launch: a fresh connection restores from disk alone.
    let secondRun = UUID()
    await registry.addConnection(id: secondRun, fileDescriptor: -1)
    await registry.handle(.restoreOpenProjects, connectionID: secondRun)

    #expect(Self.names(persistence.loadOpenProjects()) == ["project-a"])
  }

  @Test
  func removingAProjectForgetsItButKeepsItsLoops() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-d"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-d",
        command: .createNode(
          NodeDraft(
            title: "Research", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: connectionID)

    await registry.handle(.forgetProject(path: "/tmp/project-d"), connectionID: connectionID)

    #expect(persistence.loadOpenProjects().isEmpty)
    #expect(persistence.loadRecentProjects().isEmpty)
    // Re-adding the folder has to bring the loops back — that's the whole distinction
    // between "Remove from Graphcode" and "Delete Loops…".
    #expect(persistence.loadGraph(path: "/tmp/project-d")?.nodes.count == 1)
  }

  @Test
  func deletingAProjectsLoopsDiscardsThemForGood() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-e"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-e",
        command: .createNode(
          NodeDraft(
            title: "Research", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: connectionID)

    await registry.handle(.deleteProjectGraph(path: "/tmp/project-e"), connectionID: connectionID)
    #expect(persistence.loadGraph(path: "/tmp/project-e") == nil)

    // Reopening must start empty. The in-memory store has to have been dropped too, or
    // it would persist the graph we just deleted straight back to disk.
    await registry.handle(.openProject(path: "/tmp/project-e"), connectionID: connectionID)
    #expect(persistence.loadGraph(path: "/tmp/project-e")?.nodes.isEmpty != false)
  }

  @Test
  func deletingAProjectsLoopsEndsEverySessionFirst() async {
    // The graph is the only handle on the loops' detached sessions — deleting it with
    // them alive left every agent in the project running forever, invisible to any UI.
    // The composite's worker is the deep case: its node lives in a sub-graph, so a walk
    // of `graph.nodes` alone would miss its session.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let killed = LockIsolated<Set<UUID>>([])
    // Reads the file straight after each command, so every save is flushed first.
    let registry = ProjectRegistry(
      persistenceDirectory: directory,
      ensureSession: { _, _ in },
      terminateSession: { node, _ in _ = killed.withValue { $0.insert(node.id) } },
      persistsSynchronously: true)
    let persistence = ProjectPersistence(baseDirectory: directory)
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-f"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-f",
        command: .createNode(
          NodeDraft(title: "Watcher", loopType: .timeBased, triggerPrompt: "/loop 1h Check"))),
      connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-f",
        command: .createNode(NodeDraft(title: "Routine", loopType: .composite))),
      connectionID: connectionID)
    let saved = persistence.loadGraph(path: "/tmp/project-f")
    let compositeID = saved?.nodes.first { $0.loopType == .composite }?.id
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-f",
        command: .subGraphCommand(
          nodeID: compositeID ?? UUID(),
          command: .createNode(
            NodeDraft(title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h work")))),
      connectionID: connectionID)
    let everyLoop = Set(
      persistence.loadGraph(path: "/tmp/project-f")?.nodesAtAnyDepth.map(\.id) ?? [])
    #expect(everyLoop.count == 3)

    await registry.handle(.deleteProjectGraph(path: "/tmp/project-f"), connectionID: connectionID)

    #expect(killed.value == everyLoop)
  }

  @Test
  func deletingAClosedProjectsLoopsStillEndsTheirSessions() async {
    // A graph can be deleted while its project is closed and its loops still running —
    // a fresh daemon has no resident store for it, so the nodes come off disk. And they
    // must come off disk *without* loading a real store: `store(forProjectPath:)` runs
    // `ensureUnattendedSessions` on load, which would start sessions on the way to
    // killing them.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    // A real folder, or `routing` refuses the open, no loop is ever created, and every
    // expectation below holds for having found nothing.
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-closed-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let projectPath = project.resolvingSymlinksInPath().path
    let firstRun = ProjectRegistry(
      persistenceDirectory: directory, ensureSession: { _, _ in }, terminateSession: { _, _ in })
    let connectionID = UUID()
    await firstRun.addConnection(id: connectionID, fileDescriptor: -1)
    await firstRun.handle(.openProject(path: projectPath), connectionID: connectionID)
    await firstRun.handle(
      .graphCommand(
        projectPath: projectPath,
        command: .createNode(
          NodeDraft(title: "Watcher", loopType: .timeBased, triggerPrompt: "/loop 1h Check"))),
      connectionID: connectionID)
    // The first daemon's last act on its way out is to flush its writer; the second
    // daemon below only ever exists after that.
    firstRun.flushPersistence()
    let persistence = ProjectPersistence(baseDirectory: directory)
    let nodeID = persistence.loadGraph(path: projectPath)?.nodes.first?.id
    #expect(nodeID != nil, "nothing was created, so what follows would pass for finding none")

    let killed = LockIsolated<Set<UUID>>([])
    let started = LockIsolated<Set<UUID>>([])
    let secondRun = ProjectRegistry(
      persistenceDirectory: directory,
      ensureSession: { node, _ in _ = started.withValue { $0.insert(node.id) } },
      terminateSession: { node, _ in _ = killed.withValue { $0.insert(node.id) } })
    let freshConnection = UUID()
    await secondRun.addConnection(id: freshConnection, fileDescriptor: -1)
    await secondRun.handle(
      .deleteProjectGraph(path: projectPath), connectionID: freshConnection)

    #expect(killed.value == Set([nodeID].compactMap { $0 }))
    #expect(started.value.isEmpty)
    #expect(persistence.loadGraph(path: projectPath) == nil)
  }

  /// The same delete with the writer running as it does in production — asynchronously,
  /// with a save for this very project still queued. The graph must go and stay gone: a
  /// drain landing after `deleteGraph` would rewrite the file, and a `load` still
  /// answering from the queue would hand the deleted loops to the next reader.
  /// The bug this guards: a folder added from outside the app — `graphcode status
  /// <folder>`, which is how an editor plugin adds one — was persisted into the open set
  /// but reached no *running* app, so it appeared to have been ignored and only showed up
  /// after a quit and relaunch, when the app asked for the whole set back.
  @Test
  func aProjectOpenedByAnotherClientReachesAnAlreadyRunningSidebar() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let (daemonEnd, sidebarEnd) = (fds[0], fds[1])
    defer {
      close(daemonEnd)
      close(sidebarEnd)
    }

    let (registry, _) = makeRegistryAndPersistence()
    let sidebar = UUID()
    let cli = UUID()

    async let driver: Void = {
      await registry.addConnection(id: sidebar, fileDescriptor: daemonEnd)
      // The app's launch sequence, against an empty open set: nothing to restore, but
      // this is what says "I am a sidebar" — the only thing that makes the open below
      // any of its business.
      await registry.handle(.restoreOpenProjects, connectionID: sidebar)
      await registry.addConnection(id: cli, fileDescriptor: -1)
      await registry.handle(.openProject(path: "/tmp/project-h"), connectionID: cli)
    }()

    let event = try JSONDecoder().decode(
      DaemonEvent.self, from: try await readFrameOffThread(sidebarEnd))
    guard case .graphChanged(let graph) = event else {
      Issue.record("expected a graphChanged event, got \(event)")
      return
    }
    #expect(URL(fileURLWithPath: graph.project.path).lastPathComponent == "project-h")

    await driver
  }

  /// The other half of the same rule, and the reason it isn't simply "tell everyone":
  /// `graphcode`'s own connection reads frames until the project it named comes back
  /// (`runAndPrintGraph`), so a project someone else opened arriving on that socket would
  /// be printed as if it were the answer.
  @Test
  func aOneShotCLIConnectionIsNotJoinedToProjectsItDidNotOpen() async throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let (daemonEnd, cliEnd) = (fds[0], fds[1])
    defer {
      close(daemonEnd)
      close(cliEnd)
    }

    let (registry, _) = makeRegistryAndPersistence()
    let firstCLI = UUID()
    let secondCLI = UUID()

    async let driver: Void = {
      await registry.addConnection(id: firstCLI, fileDescriptor: daemonEnd)
      await registry.handle(.openProject(path: "/tmp/project-h"), connectionID: firstCLI)
      await registry.addConnection(id: secondCLI, fileDescriptor: -1)
      await registry.handle(.openProject(path: "/tmp/project-i"), connectionID: secondCLI)
    }()

    let event = try JSONDecoder().decode(
      DaemonEvent.self, from: try await readFrameOffThread(cliEnd))
    guard case .graphChanged(let graph) = event else {
      Issue.record("expected a graphChanged event, got \(event)")
      return
    }
    #expect(URL(fileURLWithPath: graph.project.path).lastPathComponent == "project-h")

    await driver
    #expect(!hasPendingBytes(cliEnd))
  }

  /// Paths round-trip through `resolvingSymlinksInPath()`, so compare the leaf rather
  /// than assuming `/tmp` survives as written.
  private static func names(_ paths: [String]) -> [String] {
    paths.map { URL(fileURLWithPath: $0).lastPathComponent }
  }
}

/// Whether anything at all is waiting to be read — how "this socket was told nothing
/// more" is asserted, without a timeout that would make the test slow when it passes.
private func hasPendingBytes(_ fileDescriptor: Int32) -> Bool {
  var byte: UInt8 = 0
  let peeked = recv(fileDescriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
  return peeked > 0
}

@Sendable
private func readFrameOffThread(_ fileDescriptor: Int32) async throws -> Data {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        continuation.resume(returning: try FramedMessageIO.readFrame(from: fileDescriptor))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

/// Kept out of the suite's body only to stay inside swiftlint's `type_body_length`.
extension ProjectRegistryTests {
  @Test
  func deletingAProjectWithASaveStillQueuedDoesNotBringItBack() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    // A real folder: `routing` refuses a path with nothing at it, and a test that skips
    // this creates no loops at all and then passes for having found none.
    let project = FileManager.default.temporaryDirectory
      .appendingPathComponent("project-queued-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let path = project.resolvingSymlinksInPath().path

    let killed = LockIsolated<Set<UUID>>([])
    let registry = ProjectRegistry(
      persistenceDirectory: directory,
      ensureSession: { _, _ in },
      terminateSession: { node, _ in _ = killed.withValue { $0.insert(node.id) } })
    let persistence = ProjectPersistence(baseDirectory: directory)
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: path), connectionID: connectionID)
    for index in 0..<8 {
      await registry.handle(
        .graphCommand(
          projectPath: path,
          command: .createNode(
            NodeDraft(
              title: "Watcher\(index)", loopType: .timeBased, triggerPrompt: "/loop 1h Check"))),
        connectionID: connectionID)
    }

    // Deliberately no flush: the delete races the writer, the way it does in a daemon
    // that is still running.
    await registry.handle(.deleteProjectGraph(path: path), connectionID: connectionID)
    #expect(killed.value.count == 8)

    registry.flushPersistence()
    #expect(persistence.loadGraph(path: path) == nil, "a queued save rewrote a deleted graph")
  }
}
