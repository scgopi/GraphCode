import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailboardKit
import Testing

/// The Mailboard's daemon half: posting, cursors, subscriptions and watcher wakes.
/// Runs against a bare `GraphStore` with injected closures — no daemon, no socket,
/// no zmx — the same harness `GraphStoreTests` uses.
@Suite
struct MailboardTests {
  /// Two loops to talk about: an author and a reader. Turn-based so nothing
  /// auto-starts a session.
  private func makeStore(
    enabled: Bool = true,
    delivered: LockIsolated<[(UUID, String)]>? = nil,
    memory: LockIsolated<[(UUID, String)]>? = nil
  ) async -> GraphStore {
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { node, message, _ in
        delivered?.withValue { $0.append((node.id, message)) }
        return true
      },
      onAppendMemory: { nodeID, entry in
        memory?.withValue { $0.append((nodeID, entry)) }
      },
      onMailboardEnabled: { enabled })
    await store.handle(.createNode(NodeDraft(title: "Author", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(.createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    return store
  }

  private func nodeIDs(_ graph: LoopGraph) -> [UUID] { graph.nodes.map(\.id) }

  @Test
  func postLandsOnGraphWithSequenceAndAttribution() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.mailboardPost(text: "  issue #12 is mine  ", topic: "Claims", from: ids[0]))

    let graph = await store.graph
    #expect(graph.mailboard.count == 1)
    let post = graph.mailboard[0]
    #expect(post.id == 1)
    #expect(post.author == "Author")
    #expect(post.authorID == ids[0])
    #expect(post.topic == "claims")
    #expect(post.body == "issue #12 is mine")
  }

  @Test
  func postIsRefusedWhileRampHasFeatureOff() async {
    let store = await makeStore(enabled: false)
    let ids = nodeIDs(await store.graph)

    await store.handle(.mailboardPost(text: "hello", topic: nil, from: ids[0]))

    let graph = await store.graph
    #expect(graph.mailboard.isEmpty)
  }

  @Test
  func emptyAndOversizedPostsAreRefused() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.mailboardPost(text: "   ", topic: nil, from: ids[0]))
    await store.handle(.mailboardPost(text: String(repeating: "x", count: 2000), topic: nil, from: ids[0]))
    await store.handle(.mailboardPost(text: "ok", topic: String(repeating: "t", count: 100), from: ids[0]))
    await store.handle(.mailboardPost(text: "ok", topic: "  ", from: ids[0]))

    let graph = await store.graph
    #expect(graph.mailboard.isEmpty)
  }

  @Test
  func idsKeepGrowingAfterPruning() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    for index in 0..<(Mailboard.maxPosts + 5) {
      await store.handle(.mailboardPost(text: "post \(index)", topic: nil, from: ids[0]))
    }

    let graph = await store.graph
    #expect(graph.mailboard.count == Mailboard.maxPosts)
    #expect(graph.mailboard.first?.body == "post 5")
    #expect(graph.mailboard.last?.id == Mailboard.maxPosts + 5)
  }

  @Test
  func syncAdvancesCursorAndNeverMovesItBackward() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.mailboardPost(text: "one", topic: nil, from: ids[0]))
    await store.handle(.mailboardSync(from: ids[1]))
    var graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.lastMailboardRead == 1)

    await store.handle(.mailboardSync(from: ids[1]))
    graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.lastMailboardRead == 1)
  }

  @Test
  func syncNeedsLoopIdentity() async {
    let store = await makeStore()

    await store.handle(.mailboardSync(from: nil))

    let graph = await store.graph
    #expect(graph.nodes.allSatisfy { $0.lastMailboardRead == nil })
  }

  @Test
  func watchSubscriptionIsSetAndCleared() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.mailboardWatch(on: true, topic: "Build", from: ids[1]))
    var graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.mailboardWatch == MailboardWatch(topic: "build"))

    await store.handle(.mailboardWatch(on: false, topic: nil, from: ids[1]))
    graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.mailboardWatch == nil)
  }

  @Test
  func matchingWatcherHearsPost() async {
    // Without a live idle session the wake is staged to the watcher's memory —
    // the durable half of the mailbox, read at the next wake.
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.mailboardWatch(on: true, topic: "build", from: ids[1]))

    await store.handle(.mailboardPost(text: "build is red", topic: "build", from: ids[0]))

    let staged = memory.value.filter { $0.0 == ids[1] && $0.1.contains("mailboard — new post #1 (build) from Author") }
    #expect(staged.count == 1)
    #expect(staged[0].1.contains("graphcode mailboard sync"))
  }

  @Test
  func topicMismatchAndSelfPostDoNotWake() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.mailboardWatch(on: true, topic: "build", from: ids[1]))

    await store.handle(.mailboardPost(text: "unrelated", topic: "auth", from: ids[0]))
    await store.handle(.mailboardWatch(on: false, topic: nil, from: ids[1]))
    await store.handle(.mailboardPost(text: "again", topic: "build", from: ids[0]))

    #expect(memory.value.filter { $0.0 == ids[1] && $0.1.contains("mailboard — new post") }.isEmpty)
  }

  @Test
  func nilTopicWatcherHearsEveryPost() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.mailboardWatch(on: true, topic: nil, from: ids[1]))

    await store.handle(.mailboardPost(text: "a", topic: "auth", from: ids[0]))
    await store.handle(.mailboardPost(text: "b", topic: nil, from: ids[0]))

    #expect(memory.value.filter { $0.0 == ids[1] && $0.1.contains("mailboard — new post") }.count == 2)
  }

  @Test
  func graphRoundTripsMailboardThroughCodable() throws {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.mailboard = [
      MailboardPost(
        id: 3, at: Date(timeIntervalSince1970: 100), authorID: nil,
        author: "a human", topic: "t", body: "b")
    ]
    var node = LoopNode(title: "n", loopType: .turnBased)
    node.lastMailboardRead = 3
    node.mailboardWatch = MailboardWatch(topic: "t")
    graph.nodes.append(node)

    let data = try JSONEncoder().encode(graph)
    let decoded = try JSONDecoder().decode(LoopGraph.self, from: data)

    #expect(decoded.mailboard == graph.mailboard)
    #expect(decoded.nodes[0].lastMailboardRead == 3)
    #expect(decoded.nodes[0].mailboardWatch == MailboardWatch(topic: "t"))

    // Graphs saved before the Mailboard decode with an empty board and no cursors:
    // take a fresh encoding and strip the new keys, reproducing an old file.
    let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var stripped = raw
    stripped.removeValue(forKey: "mailboard")
    var nodes = try #require(raw["nodes"] as? [[String: Any]])
    nodes[0].removeValue(forKey: "lastMailboardRead")
    nodes[0].removeValue(forKey: "mailboardWatch")
    stripped["nodes"] = nodes
    let legacyData = try JSONSerialization.data(withJSONObject: stripped)
    let old = try JSONDecoder().decode(LoopGraph.self, from: legacyData)
    #expect(old.mailboard.isEmpty)
    #expect(old.nodes[0].lastMailboardRead == nil)
    #expect(old.nodes[0].mailboardWatch == nil)
  }
}
