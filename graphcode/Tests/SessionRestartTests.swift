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
  func aNodeSavedBeforeTheCounterExistedDecodesAtZero() throws {
    let json = #"{"id":"\#(UUID().uuidString)","title":"Old"}"#
    let node = try JSONDecoder().decode(LoopNode.self, from: Data(json.utf8))
    #expect(node.sessionRestarts == 0)
  }
}
