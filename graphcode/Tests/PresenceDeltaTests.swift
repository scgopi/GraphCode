import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

#if canImport(Darwin)
  import Darwin
#endif

/// The presence tick's broadcast is the loops it moved, not the whole graph
/// (`DaemonEvent.nodesChanged`, issue #288's background load) — and a revision on every
/// frame is what lets a client hold snapshots and deltas in one sequence.
@Suite
struct PresenceDeltaTests {
  private static let project = ProjectRef(path: "/tmp/project-a", name: "project-a")

  private func node(_ title: String) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, goal: GoalSpec(summary: "done"), state: .running)
  }

  private func nextEvent(from descriptor: Int32) async throws -> DaemonEvent {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do {
          let data = try FramedMessageIO.readFrame(from: descriptor)
          continuation.resume(returning: try JSONDecoder().decode(DaemonEvent.self, from: data))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func nothingPending(on descriptor: Int32) -> Bool {
    var probe = [UInt8](repeating: 0, count: 1)
    let peeked = recv(descriptor, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
    return peeked < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
  }

  private actor Readings {
    private var answers: [String: Presence] = [:]
    func set(_ title: String, _ presence: Presence) { answers[title] = presence }
    func read(_ node: LoopNode) -> PresenceReading {
      PresenceReading(presence: answers[node.title] ?? .idle, confidence: .reported)
    }
  }

  @Test
  func aTickShipsOnlyTheLoopsItMovedAndNothingWhenNoneDid() async throws {
    let readings = Readings()
    var graph = LoopGraph(project: Self.project)
    graph.nodes.append(node("Still"))
    graph.nodes.append(node("Moving"))
    let store = GraphStore(
      graph: graph, onEnsureSession: { _, _ in },
      onReadPresence: { node, _ in await readings.read(node) })
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      OutboundChannels.close(pair[0])
      close(pair[1])
    }
    await store.addConnection(id: UUID(), fileDescriptor: pair[0])
    guard case .graphChanged(let joined) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the joining snapshot")
      return
    }
    let joinedRevision = try #require(joined.revision)

    // First tick: both loops get their first reading, so both move.
    await store.pollPresence()
    guard case .nodesChanged(let path, let first, let both) = try await nextEvent(from: pair[1])
    else {
      Issue.record("expected a delta")
      return
    }
    #expect(path == Self.project.path)
    #expect(first > joinedRevision)
    #expect(Set(both.map(\.title)) == ["Still", "Moving"])

    // Second tick: one reading changes, one frame, one loop in it.
    await readings.set("Moving", .busy)
    await store.pollPresence()
    guard case .nodesChanged(_, let second, let moved) = try await nextEvent(from: pair[1])
    else {
      Issue.record("expected a delta for the loop that moved")
      return
    }
    #expect(second > first)
    #expect(moved.map(\.title) == ["Moving"])
    #expect(moved[0].presence?.presence == .busy)

    // Third tick: nothing changed, nothing sent.
    await store.pollPresence()
    #expect(nothingPending(on: pair[1]))

    // A command still broadcasts a whole snapshot, stamped later in the same sequence.
    await store.handle(.renameNode(graph.nodes[0].id, title: "Renamed"))
    guard case .graphChanged(let renamed) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected a snapshot for the rename")
      return
    }
    #expect(try #require(renamed.revision) > second)
    #expect(renamed.nodes[0].title == "Renamed")
    #expect(renamed.nodes[1].presence?.presence == .busy)
  }

  @Test
  func aDeltaAppliesByIdAndNeverInventsALoop() {
    var graph = LoopGraph(project: Self.project)
    let kept = node("Kept")
    graph.nodes.append(kept)
    var moved = kept
    moved.presence = PresenceReading(presence: .busy, confidence: .reported)
    let stranger = node("Stranger")

    let applied = graph.applying(nodesChanged: [moved, stranger], revision: 7)
    #expect(applied.nodes.map(\.title) == ["Kept"])
    #expect(applied.nodes[0].presence?.presence == .busy)
    #expect(applied.revision == 7)
  }

  /// The app folds a delta into the snapshot it holds and handles the result as a
  /// snapshot; a delta older than what it holds — one a superseding snapshot overtook
  /// in the daemon's queue — is dropped.
  @Test
  @MainActor
  func theAppFoldsADeltaIntoItsSnapshotAndDropsAStaleOne() async {
    let loop = node("Loop")
    var held = LoopGraph(project: Self.project, nodes: [loop])
    held.revision = 5
    var state = AppFeature.State()
    state.projects.append(ProjectFeature.State(graph: held))
    state.openLoop = LoopWorkspaceFeature.State(
      node: loop, layout: .defaultLayout(forNode: loop.id), projectPath: Self.project.path,
      projectName: Self.project.name)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    var busy = loop
    busy.presence = PresenceReading(presence: .busy, confidence: .reported)
    await store.send(
      .daemonEvent(.nodesChanged(projectPath: Self.project.path, revision: 6, nodes: [busy])))
    // The fold re-dispatches a snapshot, which the app hands its project one hop down.
    await store.receive(\.daemonEvent)
    await store.receive(\.projects)
    #expect(store.state.projects[id: Self.project.path]?.graph.revision == 6)
    #expect(store.state.openLoop?.node.presence?.presence == .busy)

    var idle = loop
    idle.presence = PresenceReading(presence: .idle, confidence: .reported)
    await store.send(
      .daemonEvent(.nodesChanged(projectPath: Self.project.path, revision: 4, nodes: [idle])))
    await store.finish()
    #expect(store.state.projects[id: Self.project.path]?.graph.revision == 6)
    #expect(store.state.openLoop?.node.presence?.presence == .busy)
  }
}
