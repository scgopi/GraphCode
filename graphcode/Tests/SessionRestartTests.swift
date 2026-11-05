import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// `GraphCommand.restartNode` / `.restartSessions` — kill a session and bring it back on
/// the same transcript. The store's part is small and all about the counter: it moves
/// only for a confirmed kill, because the app remounts a pane on it.
@Suite
struct SessionRestartTests {
  private func draft(_ title: String) -> NodeDraft {
    NodeDraft(title: title, loopType: .goalBased, goal: GoalSpec(summary: "say hi"))
  }

  @Test
  func aConfirmedKillBumpsTheCounterAndLeavesAMemo() async {
    let restarted = LockIsolated<[(UUID, String?)]>([])
    let memos = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")),
      onRestartSession: { node, path in
        restarted.withValue { $0.append((node.id, path)) }
        return true
      },
      onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
    await store.handle(.createNode(draft("Worker")))
    let id = await store.graph.nodes[0].id

    await store.handle(.restartNode(id))

    #expect(await store.graph.nodes[id: id]?.sessionRestarts == 1)
    #expect(restarted.value.map(\.0) == [id])
    #expect(restarted.value.map(\.1) == ["/tmp/p"])
    #expect(memos.value.contains { $0.contains("restarted in place") })
  }

  @Test
  func aKillThatDidNotLandLeavesTheCounterAloneAndSaysSo() async {
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      onRestartSession: { _, _ in false },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(.createNode(draft("Stuck")))
    let id = await store.graph.nodes[0].id

    await store.handle(.restartNode(id))

    #expect(await store.graph.nodes[id: id]?.sessionRestarts == 0)
    #expect(errors.value.count == 1)
  }

  @Test
  func aFinishedLoopIsRefused() async {
    let restarted = LockIsolated(0)
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      onRestartSession: { _, _ in
        restarted.withValue { $0 += 1 }
        return true
      },
      onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(.createNode(draft("Done")))
    let id = await store.graph.nodes[0].id
    await store.handle(.nodeCheckApproved(id))

    await store.handle(.restartNode(id))

    #expect(restarted.value == 0)
    #expect(errors.value.count == 1)
  }

  /// A refused restart changes nothing, so no `.graphChanged` acknowledges it: the
  /// asking CLI hears only the refusal, and a bystander's CLI, parked on a verdict of its
  /// own, must not take a broadcast copy for one.
  @Test
  func aRefusedRestartAnswersOnlyTheConnectionThatAsked() async throws {
    let store = GraphStore(onRestartSession: { _, _ in true })
    await store.handle(.createNode(draft("Done")))
    let id = await store.graph.nodes[0].id
    await store.handle(.nodeCheckApproved(id))
    var asker: [Int32] = [0, 0]
    var bystander: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &asker) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &bystander) == 0)
    defer {
      for descriptor in [asker[0], asker[1], bystander[0], bystander[1]] { close(descriptor) }
    }
    let askerID = UUID()
    await store.addConnection(id: askerID, fileDescriptor: asker[0])
    await store.addConnection(id: UUID(), fileDescriptor: bystander[0])
    guard case .graphChanged = try nextEvent(from: asker[1]),
      case .graphChanged = try nextEvent(from: bystander[1])
    else {
      Issue.record("expected each connection's joining snapshot")
      return
    }

    await store.handle(.restartNode(id), from: askerID)

    guard case .errorOccurred(let message) = try nextEvent(from: asker[1]) else {
      Issue.record("the asker heard nothing, so its CLI waits out its timeout")
      return
    }
    #expect(message == "Done has finished — there is no session to restart")
    var reached: [String] = []
    while let event = try nextEvent(from: bystander[1], waiting: 1) {
      if case .errorOccurred(let message) = event { reached.append(message) }
    }
    #expect(reached.isEmpty)
  }

  /// Blocking read with a deadline: `OutboundChannels` writes off the actor, so a
  /// non-blocking read straight after `handle` races the delivery.
  private func nextEvent(from descriptor: Int32, waiting seconds: Int32 = 2) throws
    -> DaemonEvent?
  {
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var length: UInt32 = 0
    var header = [UInt8](repeating: 0, count: 4)
    guard recv(descriptor, &header, 4, MSG_WAITALL) == 4 else { return nil }
    withUnsafeMutableBytes(of: &length) { $0.copyBytes(from: header) }
    var payload = [UInt8](repeating: 0, count: Int(UInt32(bigEndian: length)))
    guard recv(descriptor, &payload, payload.count, MSG_WAITALL) == payload.count else {
      return nil
    }
    return try JSONDecoder().decode(DaemonEvent.self, from: Data(payload))
  }

  @Test
  func restartingEverySessionSkipsTheFinishedOnes() async {
    let restarted = LockIsolated<Set<UUID>>([])
    let store = GraphStore(
      onRestartSession: { node, _ in
        restarted.withValue { $0.insert(node.id) }
        return true
      })
    await store.handle(.createNode(draft("Live")))
    await store.handle(.createNode(draft("Also live")))
    await store.handle(.createNode(draft("Done")))
    let ids = await store.graph.nodes.map(\.id)
    await store.handle(.nodeCheckApproved(ids[2]))

    await store.handle(.restartSessions)

    #expect(restarted.value == Set(ids.prefix(2)))
    #expect(await store.graph.nodes[id: ids[0]]?.sessionRestarts == 1)
    #expect(await store.graph.nodes[id: ids[2]]?.sessionRestarts == 0)
  }

  @Test
  func aPaneExitRightAfterARestartDoesNotResolveTheLoop() async {
    let memos = LockIsolated<[String]>([])
    let store = GraphStore(
      onRestartSession: { _, _ in true },
      onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
    await store.handle(.createNode(draft("Bounced")))
    let id = await store.graph.nodes[0].id
    await store.handle(.restartNode(id))

    await store.handle(.nodeCheckRejected(id))
    await store.handle(.nodeCheckApproved(id))

    #expect(await store.graph.nodes[id: id]?.state == .running)
    #expect(memos.value.filter { $0.contains("after a restart") }.count == 2)
  }

  @Test
  func aPaneClosingOnALiveSessionDoesNotResolveTheLoop() async {
    let alive = LockIsolated(true)
    let memos = LockIsolated<[String]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in alive.value },
      onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
    await store.handle(.createNode(draft("Closed on")))
    let id = await store.graph.nodes[0].id

    await store.handle(.nodeCheckRejected(id))
    #expect(await store.graph.nodes[id: id]?.state == .running)
    #expect(memos.value.contains { $0.contains("still live — not resolved") })

    alive.setValue(false)
    await store.handle(.nodeCheckRejected(id))
    #expect(await store.graph.nodes[id: id]?.state == .failed)
    #expect(
      memos.value.contains {
        $0.contains("resolved: failed — its pane closed with the process still running")
      })
  }

  @Test
  func aNodeSavedBeforeTheCounterExistedDecodesAtZero() throws {
    let json = #"{"id":"\#(UUID().uuidString)","title":"Old"}"#
    let node = try JSONDecoder().decode(LoopNode.self, from: Data(json.utf8))
    #expect(node.sessionRestarts == 0)
  }
}
