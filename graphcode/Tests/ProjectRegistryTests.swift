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
    for name in ["project-a", "project-b", "project-c", "project-d", "project-e"] {
      try FileManager.default.createDirectory(
        atPath: "/tmp/\(name)", withIntermediateDirectories: true)
    }
  }

  private func makeRegistryAndPersistence() -> (ProjectRegistry, ProjectPersistence) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return (
      ProjectRegistry(persistenceDirectory: directory), ProjectPersistence(baseDirectory: directory)
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

  @Test
  func applyReturnsRejectedCommandWithoutASuccessSnapshot() async {
    let (registry, persistence) = makeRegistryAndPersistence()
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connectionID)

    let result = await registry.apply(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(NodeDraft(title: "No goal", loopType: .goalBased))),
      connectionID: connectionID)

    #expect(result?.error == "node creation refused: draft is invalid")
    #expect(result?.response == nil)
    #expect(persistence.loadGraph(path: "/tmp/project-a")?.nodes.isEmpty != false)
  }

  @Test
  func concurrentApplyResponsesContainTheSnapshotFromTheirOwnCommand() async {
    let (registry, _) = makeRegistryAndPersistence()
    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connectionID)

    async let firstResult = registry.apply(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(
          NodeDraft(
            title: "First", loopType: .turnBased, checkDescription: "Sound?",
            firstInstruction: "Work"))),
      connectionID: connectionID)
    async let secondResult = registry.apply(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createNode(
          NodeDraft(
            title: "Second", loopType: .turnBased, checkDescription: "Clear?",
            firstInstruction: "Work"))),
      connectionID: connectionID)

    let results = [await firstResult, await secondResult].compactMap { result -> LoopGraph? in
      guard let response = result?.response, case .graphChanged(let graph) = response else {
        Issue.record("expected a correlated graph snapshot for each applied command")
        return nil
      }
      return graph
    }

    #expect(results.count == 2)
    #expect(results.contains { $0.nodes.count == 1 && $0.nodes.contains { $0.title == "First" } })
    #expect(
      results.contains {
        $0.nodes.count == 2
          && Set($0.nodes.map(\.title)) == Set(["First", "Second"])
      })
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
  func broadcastWriteFailureEvictsTheConnectionAndClosesItsTransport() async throws {
    let (registry, _) = makeRegistryAndPersistence()
    let connection = FailingConnection()
    await registry.addConnection(id: connection.id, connection: connection)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connection.id)

    for _ in 0..<100 where !connection.isClosed {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(connection.isClosed)
    #expect(connection.sendAttempts == 1)

    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: connection.id)
    #expect(connection.sendAttempts == 1)
  }

  /// Paths round-trip through `resolvingSymlinksInPath()`, so compare the leaf rather
  /// than assuming `/tmp` survives as written.
  private static func names(_ paths: [String]) -> [String] {
    paths.map { URL(fileURLWithPath: $0).lastPathComponent }
  }
}

private final class FailingConnection: @unchecked Sendable, DaemonConnection {
  let id = UUID()
  let endpoint: DaemonEndpoint = .namedPipe("failing")
  private let lock = NSLock()
  private var closed = false
  private var attempts = 0

  var isClosed: Bool {
    lock.withLock { closed }
  }

  var sendAttempts: Int {
    lock.withLock { attempts }
  }

  func receiveFrame() async throws -> Data {
    throw FramedMessageIO.IOError.connectionClosed
  }

  func sendFrame(_ data: Data) async throws {
    lock.withLock { attempts += 1 }
    throw FramedMessageIO.IOError.writeFailed(errno: 1)
  }

  func close() async throws {
    lock.withLock { closed = true }
  }
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
