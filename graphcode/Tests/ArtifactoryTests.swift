import ArtifactoryKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The Artifactory's daemon half: posting, cursors, subscriptions and watcher wakes.
/// Runs against a bare `GraphStore` with injected closures — no daemon, no socket,
/// no zmx — the same harness `GraphStoreTests` uses.
@Suite
struct ArtifactoryTests {
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
      onArtifactoryEnabled: { enabled })
    await store.handle(.createNode(NodeDraft(title: "Author", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(.createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    return store
  }

  private func nodeIDs(_ graph: LoopGraph) -> [UUID] { graph.nodes.map(\.id) }

  @Test
  func postLandsOnGraphWithSequenceAndAttribution() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryPost(text: "  issue #12 is mine  ", topic: "Claims", from: ids[0]))

    let graph = await store.graph
    #expect(graph.artifactory.count == 1)
    let post = graph.artifactory[0]
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

    await store.handle(.artifactoryPost(text: "hello", topic: nil, from: ids[0]))

    let graph = await store.graph
    #expect(graph.artifactory.isEmpty)
  }

  @Test
  func emptyAndOversizedPostsAreRefused() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryPost(text: "   ", topic: nil, from: ids[0]))
    await store.handle(.artifactoryPost(text: String(repeating: "x", count: 2000), topic: nil, from: ids[0]))
    await store.handle(.artifactoryPost(text: "ok", topic: String(repeating: "t", count: 100), from: ids[0]))
    await store.handle(.artifactoryPost(text: "ok", topic: "  ", from: ids[0]))

    let graph = await store.graph
    #expect(graph.artifactory.isEmpty)
  }

  @Test
  func idsKeepGrowingAfterPruning() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    for index in 0..<(Artifactory.maxPosts + 5) {
      await store.handle(.artifactoryPost(text: "post \(index)", topic: nil, from: ids[0]))
    }

    let graph = await store.graph
    #expect(graph.artifactory.count == Artifactory.maxPosts)
    #expect(graph.artifactory.first?.body == "post 5")
    #expect(graph.artifactory.last?.id == Artifactory.maxPosts + 5)
  }

  @Test
  func syncAdvancesCursorAndNeverMovesItBackward() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryPost(text: "one", topic: nil, from: ids[0]))
    await store.handle(.artifactorySync(from: ids[1]))
    var graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.lastArtifactoryRead == 1)

    await store.handle(.artifactorySync(from: ids[1]))
    graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.lastArtifactoryRead == 1)
  }

  @Test
  func syncNeedsLoopIdentity() async {
    let store = await makeStore()

    await store.handle(.artifactorySync(from: nil))

    let graph = await store.graph
    #expect(graph.nodes.allSatisfy { $0.lastArtifactoryRead == nil })
  }

  @Test
  func watchSubscriptionIsSetAndCleared() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryWatch(on: true, topic: "Build", from: ids[1]))
    var graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.artifactoryWatch == ArtifactoryWatch(topic: "build"))

    await store.handle(.artifactoryWatch(on: false, topic: nil, from: ids[1]))
    graph = await store.graph
    #expect(graph.nodes[id: ids[1]]?.artifactoryWatch == nil)
  }

  @Test
  func matchingWatcherHearsPost() async {
    // Without a live idle session the wake is staged to the watcher's memory —
    // the durable half of the mailbox, read at the next wake.
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryWatch(on: true, topic: "build", from: ids[1]))

    await store.handle(.artifactoryPost(text: "build is red", topic: "build", from: ids[0]))

    let staged = memory.value.filter {
      $0.0 == ids[1] && $0.1.contains("artifactory — new post #1 (build) from Author")
    }
    #expect(staged.count == 1)
    #expect(staged[0].1.contains("graphcode artifactory sync"))
  }

  @Test
  func topicMismatchAndSelfPostDoNotWake() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryWatch(on: true, topic: "build", from: ids[1]))

    await store.handle(.artifactoryPost(text: "unrelated", topic: "auth", from: ids[0]))
    await store.handle(.artifactoryWatch(on: false, topic: nil, from: ids[1]))
    await store.handle(.artifactoryPost(text: "again", topic: "build", from: ids[0]))

    #expect(memory.value.filter { $0.0 == ids[1] && $0.1.contains("artifactory — new post") }.isEmpty)
  }

  @Test
  func nilTopicWatcherHearsEveryPost() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryWatch(on: true, topic: nil, from: ids[1]))

    await store.handle(.artifactoryPost(text: "a", topic: "auth", from: ids[0]))
    await store.handle(.artifactoryPost(text: "b", topic: nil, from: ids[0]))

    #expect(memory.value.filter { $0.0 == ids[1] && $0.1.contains("artifactory — new post") }.count == 2)
  }

  @Test
  func graphRoundTripsArtifactoryThroughCodable() throws {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.artifactory = [
      ArtifactoryPost(
        id: 3, at: Date(timeIntervalSince1970: 100), authorID: nil,
        author: "a human", topic: "t", body: "b")
    ]
    var node = LoopNode(title: "n", loopType: .turnBased)
    node.lastArtifactoryRead = 3
    node.artifactoryWatch = ArtifactoryWatch(topic: "t")
    graph.nodes.append(node)

    let data = try JSONEncoder().encode(graph)
    let decoded = try JSONDecoder().decode(LoopGraph.self, from: data)

    #expect(decoded.artifactory == graph.artifactory)
    #expect(decoded.nodes[0].lastArtifactoryRead == 3)
    #expect(decoded.nodes[0].artifactoryWatch == ArtifactoryWatch(topic: "t"))

    // Graphs saved before the Artifactory decode with an empty board and no cursors:
    // take a fresh encoding and strip the new keys, reproducing an old file.
    let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var stripped = raw
    stripped.removeValue(forKey: "artifactory")
    var nodes = try #require(raw["nodes"] as? [[String: Any]])
    nodes[0].removeValue(forKey: "lastArtifactoryRead")
    nodes[0].removeValue(forKey: "artifactoryWatch")
    stripped["nodes"] = nodes
    let legacyData = try JSONSerialization.data(withJSONObject: stripped)
    let old = try JSONDecoder().decode(LoopGraph.self, from: legacyData)
    #expect(old.artifactory.isEmpty)
    #expect(old.nodes[0].lastArtifactoryRead == nil)
    #expect(old.nodes[0].artifactoryWatch == nil)
  }
}

/// The mirroring and deletion halves live in an extension to keep the suite under swiftlint's body-length bound.
extension ArtifactoryTests {  // MARK: - Shared-communication mirroring
  @Test
  func directMessageMirrorsOntoArtifactory() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.messageNode(ids[1], text: "the API changed under you", from: ids[0], followUp: nil))

    let graph = await store.graph
    #expect(graph.artifactory.count == 1)
    let record = graph.artifactory[0]
    #expect(record.topic == "direct")
    #expect(record.author == "Author")
    #expect(record.body == "@Reader: the API changed under you")
  }

  @Test
  func watcherWakesDoNotMirrorThemselves() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryWatch(on: true, topic: "build", from: ids[1]))

    await store.handle(.artifactoryPost(text: "build is red", topic: "build", from: ids[0]))

    // One post — the wake staged to the watcher must not become a post of its own.
    let graph = await store.graph
    #expect(graph.artifactory.count == 1)
    #expect(memory.value.contains { $0.0 == ids[1] && $0.1.contains("artifactory — new post #1") })
  }

  @Test
  func deliveredMessageEdgeMirrorsOntoArtifactory() async {
    let delivered = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(delivered: delivered)
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .createEdge(
        from: ids[0], to: ids[1],
        spec: EdgeSpec(kind: .message, payloadTransform: .template("specs moved to docs/api.md"))))
    await store.handle(.nodeCheckApproved(ids[0]))

    let graph = await store.graph
    #expect(graph.edges[0].fired)
    let records = graph.artifactory.filter { $0.topic == "direct" }
    #expect(records.count == 1)
    #expect(records[0].author == "Author")
    #expect(records[0].body == "@Reader: specs moved to docs/api.md")
  }

  @Test
  func handoffMirrorsOntoArtifactoryWithPayload() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .createEdge(
        from: ids[0], to: ids[1],
        spec: EdgeSpec(kind: .handoff, payloadTransform: .template("branch: fix/auth"))))
    await store.handle(.nodeCheckApproved(ids[0]))

    let graph = await store.graph
    let records = graph.artifactory.filter { $0.topic == "handoff" }
    #expect(records.count == 1)
    #expect(records[0].author == "Author")
    #expect(
      records[0].body
        == "@Reader: Author finished and handed its work off to you. branch: fix/auth")
  }

  // MARK: - Deletion

  @Test
  func deletingALoopRemovesItsArtifactoryPosts() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryPost(text: "mine", topic: nil, from: ids[0]))
    await store.handle(.artifactoryPost(text: "theirs", topic: nil, from: ids[1]))

    await store.handle(.deleteNode(ids[0]))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.artifactory.map(\.body) == ["theirs"])
  }

  @Test
  func deletingALoopKeepsPostsWhereItWasOnlyTheRecipient() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)
    await store.handle(.messageNode(ids[1], text: "for you", from: ids[0], followUp: nil))
    #expect(await store.graph.artifactory.count == 1)

    await store.handle(.deleteNode(ids[1]))

    let graph = await store.graph
    // The record of what was said stays; only the departed loop's own words go.
    #expect(graph.artifactory.count == 1)
    #expect(graph.artifactory[0].body == "@Reader: for you")
  }

  @Test
  func deletingALoopRemovesItsSpawnedDescendantsPostsToo() async throws {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Child", loopType: .turnBased, firstInstruction: "Work",
          createdBy: ids[0])))
    let childID = try #require((await store.graph.nodes.first { $0.createdBy == ids[0] })?.id)
    await store.handle(.artifactoryPost(text: "child note", topic: nil, from: childID))
    await store.handle(.artifactoryPost(text: "parent note", topic: nil, from: ids[0]))

    await store.handle(.deleteNode(ids[0]))

    let graph = await store.graph
    // Custody: the child went with the parent, and its board record goes too.
    #expect(graph.artifactory.isEmpty)
  }
}
