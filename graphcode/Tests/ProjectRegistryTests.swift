import Foundation
import GraphcodeKit
import Testing

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
        command: .createTurnBasedNode(title: "Research", checkDescription: "Sound?")),
      connectionID: firstConnection)

    let secondConnection = UUID()
    await registry.addConnection(id: secondConnection, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-a"), connectionID: secondConnection)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-a",
        command: .createTurnBasedNode(title: "Implement", checkDescription: "Correct?")),
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
        command: .createTurnBasedNode(title: "Research", checkDescription: "Sound?")),
      connectionID: connectionID)

    await registry.handle(.openProject(path: "/tmp/project-b"), connectionID: connectionID)
    await registry.handle(
      .graphCommand(
        projectPath: "/tmp/project-b",
        command: .createTurnBasedNode(title: "Design", checkDescription: "Clear?")),
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
        command: .createTurnBasedNode(title: "Research", checkDescription: "Sound?")),
      connectionID: UUID())
  }

  @Test
  func openingAProjectRecordsItAsRecentlyOpened() async {
    let (registry, persistence) = makeRegistryAndPersistence()

    let connectionID = UUID()
    await registry.addConnection(id: connectionID, fileDescriptor: -1)
    await registry.handle(.openProject(path: "/tmp/project-c"), connectionID: connectionID)

    #expect(persistence.loadRecentProjects().contains { $0.path == "/tmp/project-c" })
  }
}
