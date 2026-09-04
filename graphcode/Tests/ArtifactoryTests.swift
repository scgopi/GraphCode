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
    memory: LockIsolated<[(UUID, String)]>? = nil,
    errors: LockIsolated<[String]>? = nil,
    presence: Presence? = nil
  ) async -> GraphStore {
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { node, message, _ in
        delivered?.withValue { $0.append((node.id, message)) }
        return true
      },
      onReadPresence: presence.map { reading in
        { _, _ in PresenceReading(presence: reading, confidence: .reported) }
      },
      onAppendMemory: { nodeID, entry in
        memory?.withValue { $0.append((nodeID, entry)) }
      },
      onAnnounceError: { message in errors?.withValue { $0.append(message) } },
      onArtifactoryEnabled: { enabled })
    await store.handle(
      .createNode(NodeDraft(title: "Author", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(
      .createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    return store
  }

  private func nodeIDs(_ graph: LoopGraph) -> [UUID] { graph.nodes.map(\.id) }

  @Test
  func postLandsOnGraphWithSequenceAndAttribution() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .artifactoryPost(text: "  issue #12 is mine  ", topic: "Claims", from: ids[0]))

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
    await store.handle(
      .artifactoryPost(text: String(repeating: "x", count: 2000), topic: nil, from: ids[0]))
    await store.handle(
      .artifactoryPost(text: "ok", topic: String(repeating: "t", count: 100), from: ids[0]))
    await store.handle(.artifactoryPost(text: "ok", topic: "  ", from: ids[0]))

    let graph = await store.graph
    #expect(graph.artifactory.isEmpty)
  }

  @Test
  func idsKeepGrowingAfterPruning() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    for index in 0..<(Artifactory.maxNotes + 5) {
      await store.handle(.artifactoryPost(text: "post \(index)", topic: nil, from: ids[0]))
    }

    let graph = await store.graph
    #expect(graph.artifactory.count == Artifactory.maxNotes)
    #expect(graph.artifactory.first?.body == "post 5")
    #expect(graph.artifactory.last?.id == Artifactory.maxNotes + 5)
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

    #expect(
      memory.value.filter { $0.0 == ids[1] && $0.1.contains("artifactory — new post") }
        .isEmpty)
  }

  @Test
  func nilTopicWatcherHearsEveryPost() async {
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(memory: memory)
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryWatch(on: true, topic: nil, from: ids[1]))

    await store.handle(.artifactoryPost(text: "a", topic: "auth", from: ids[0]))
    await store.handle(.artifactoryPost(text: "b", topic: nil, from: ids[0]))

    #expect(
      memory.value.filter { $0.0 == ids[1] && $0.1.contains("artifactory — new post") }
        .count == 2)
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

    await store.handle(
      .messageNode(ids[1], text: "the API changed under you", from: ids[0], followUp: nil))

    let graph = await store.graph
    #expect(graph.artifactory.count == 1)
    let record = graph.artifactory[0]
    #expect(record.topic == "direct")
    #expect(record.author == "Author")
    #expect(record.body == "@Reader: the API changed under you")
    #expect(record.wasWritten)
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
    #expect(records[0].wasWritten)
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
    #expect(records[0].wasWritten)
  }
}

/// #273: which mirrored posts a reader is shown. `kind` is a budget — mirrored traffic
/// prunes on its own quota so a talkative graph cannot evict a note — and it was doing
/// double duty as "is there anything in here to read". A `node send` carries every word
/// its sender typed; an edge that fired with no payload carries none.
extension ArtifactoryTests {  // MARK: - Written messages and delivery receipts
  @Test
  func aPayloadlessEdgeMirrorsAsAReceipt() async {
    let delivered = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(delivered: delivered)
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .createEdge(from: ids[0], to: ids[1], spec: EdgeSpec(kind: .message)))
    await store.handle(.nodeCheckApproved(ids[0]))

    let graph = await store.graph
    let records = graph.artifactory.filter { $0.topic == "direct" }
    #expect(records.count == 1)
    #expect(records[0].body == "@Reader: Author finished.")
    #expect(!records[0].wasWritten)
  }

  @Test
  func aPayloadlessHandoffMirrorsAsAReceipt() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .createEdge(from: ids[0], to: ids[1], spec: EdgeSpec(kind: .handoff)))
    await store.handle(.nodeCheckApproved(ids[0]))

    let graph = await store.graph
    let records = graph.artifactory.filter { $0.topic == "handoff" }
    #expect(records.count == 1)
    #expect(!records[0].wasWritten)
  }

  /// Both halves still prune on the record budget, which is the invariant the split was
  /// shaped to leave alone: a graph that merely talks must not cost a note.
  @Test
  func writtenMessagesStillPruneOnTheRecordBudget() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryPost(text: "DEAD END: approach X", topic: nil, from: ids[0]))
    for index in 0..<(Artifactory.maxRecords * 2) {
      await store.handle(
        .messageNode(ids[1], text: "ping \(index)", from: ids[0], followUp: nil))
    }

    let board = await store.graph.artifactory
    #expect(board.filter { $0.kind == .note }.count == 1)
    #expect(board.filter { $0.kind == .record }.count == Artifactory.maxRecords)
    #expect(board.filter(\.wasWritten).count == Artifactory.maxRecords + 1)
  }

  /// A board saved before the split has records that could be either. They stay folded,
  /// which is exactly where they were before this shipped.
  @Test
  func recordsSavedBeforeTheSplitDecodeAsReceipts() throws {
    let json = """
      {"id":9,"at":747000000,"author":"Author","body":"@Reader: hi","kind":"record"}
      """
    let post = try JSONDecoder().decode(ArtifactoryPost.self, from: Data(json.utf8))
    #expect(post.kind == .record)
    #expect(!post.wasWritten)
  }

  @Test
  func aNoteIsWrittenWithoutBeingToldSo() {
    let note = ArtifactoryPost(
      id: 1, at: Date(), authorID: nil, author: "a human", topic: nil, body: "hello")
    #expect(note.wasWritten)
  }
}

extension ArtifactoryTests {
  // MARK: - Deletion

  /// Deleting a loop takes the handle to its posts, never the posts. A note is
  /// addressed to whoever comes next, peers may already have acted on it, and a board
  /// that un-says things is not a board.
  @Test
  func deletingALoopKeepsItsPostsAndTakesTheirHandle() async {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)
    await store.handle(.artifactoryPost(text: "mine", topic: nil, from: ids[0]))
    await store.handle(.artifactoryPost(text: "theirs", topic: nil, from: ids[1]))

    await store.handle(.deleteNode(ids[0]))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.artifactory.map(\.body) == ["mine", "theirs"])
    let orphaned = graph.artifactory[0]
    #expect(orphaned.authorID == nil)
    #expect(orphaned.author == "Author (deleted)")
    // The surviving loop's own post is untouched — attribution and all.
    #expect(graph.artifactory[1].authorID == ids[1])
    #expect(graph.artifactory[1].author == "Reader")
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
  func deletingALoopOrphansItsSpawnedDescendantsPostsToo() async throws {
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
    // Custody: the child went with the parent, and both their notes stay on the board
    // with the handles taken off — the descendants' words outlive them the same way.
    // Author and Child are gone; Reader, who was never in the custody chain, is not.
    #expect(graph.nodes.map(\.title) == ["Reader"])
    #expect(graph.artifactory.map(\.body) == ["child note", "parent note"])
    #expect(graph.artifactory.allSatisfy { $0.authorID == nil })
    #expect(graph.artifactory.map(\.author) == ["Child (deleted)", "Author (deleted)"])
  }
}

/// The review round (PR #229): refusals announce, bounds bind, composites inherit the
/// gate, imports start clean, and the briefing/digest announce the board exactly when
/// the daemon will honour it.
extension ArtifactoryTests {
  @Test
  func refusalAnnouncesItselfInsteadOfStayingSilent() async {
    let errors = LockIsolated<[String]>([])
    let store = await makeStore(enabled: false, errors: errors)
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryPost(text: "hello", topic: nil, from: ids[0]))

    let graph = await store.graph
    #expect(graph.artifactory.isEmpty)
    #expect(errors.value.count == 1)
    #expect(errors.value[0].contains("Artifactory is off"))
  }

  @Test
  func mirroredRecordTruncationRespectsTheBodyBound() async throws {
    let store = await makeStore()
    let ids = nodeIDs(await store.graph)

    await store.handle(
      .messageNode(ids[1], text: String(repeating: "x", count: 3000), from: ids[0], followUp: nil))

    let graph = await store.graph
    let record = try #require(graph.artifactory.first)
    #expect(record.body.utf8.count <= ArtifactoryPost.maxBodyBytes)
    #expect(record.body.hasSuffix("…"))
  }

  @Test
  func liveIdleWatcherHearsThePostThroughTheDeliveryChannel() async {
    let delivered = LockIsolated<[(UUID, String)]>([])
    let memory = LockIsolated<[(UUID, String)]>([])
    let store = await makeStore(
      delivered: delivered, memory: memory, presence: .idle)
    let ids = nodeIDs(await store.graph)
    // The poll's write is what makes stored presence real; the wake machinery reads
    // the stored reading, so a live idle watcher is this, not just the hook.
    await store.handle(.refreshUsage)
    await store.handle(.artifactoryWatch(on: true, topic: nil, from: ids[1]))

    await store.handle(.artifactoryPost(text: "build is red", topic: nil, from: ids[0]))

    // A live idle watcher gets exactly one delivery, typed now — no staging line,
    // which is the dead-session path's record, not the live one's.
    #expect(delivered.value.contains { $0.0 == ids[1] && $0.1.contains("artifactory — new post") })
    #expect(!memory.value.contains { $0.0 == ids[1] && $0.1.contains("follow-up staged") })
    #expect(!memory.value.contains { $0.0 == ids[1] && $0.1.contains("while you were away") })
  }

  @Test
  func compositeWorkerInheritsTheGateInsteadOfAMisleadingRefusal() async throws {
    let errors = LockIsolated<[String]>([])
    let store = await makeStore(errors: errors)
    var sub = LoopGraph(project: ProjectRef(path: "/tmp/sub", name: "sub"))
    sub.nodes.append(LoopNode(title: "Worker", loopType: .turnBased, firstInstruction: "Work"))
    await store.handle(
      .createNode(NodeDraft(title: "Orchestrator", loopType: .composite, subGraph: sub)))

    // The draft re-identifies the sub-graph, so the worker is fetched from the
    // stored composite, never from the value this test built.
    let composite = try #require(await store.graph.nodes.first { $0.loopType == .composite })
    let workerID = try #require(composite.subGraph?.nodes.first?.id)
    await store.handle(
      .subGraphCommand(
        nodeID: composite.id,
        command: .artifactoryPost(text: "worker note", topic: nil, from: workerID)))

    let graph = await store.graph
    #expect(errors.value.isEmpty)
    #expect(graph.nodes[id: composite.id]?.subGraph?.artifactory.map(\.body) == ["worker note"])
  }

  @Test
  func importedLoopStartsWithACleanCursor() async throws {
    let store = await makeStore()
    var arriving = LoopGraph(project: ProjectRef(path: "/tmp/src", name: "src"))
    var node = LoopNode(title: "Visitor", loopType: .turnBased, firstInstruction: "Work")
    node.lastArtifactoryRead = 5
    arriving.nodes.append(node)

    await store.handle(
      .importNodes(GraphImportRequest(snapshot: arriving)))

    let graph = await store.graph
    let imported = try #require(graph.nodes.first { $0.title == "Visitor" })
    #expect(imported.lastArtifactoryRead == nil)
  }

  @Test
  func watchOffWhenNotWatchingIsAHarmlessNoOp() async {
    let errors = LockIsolated<[String]>([])
    let store = await makeStore(errors: errors)
    let ids = nodeIDs(await store.graph)

    await store.handle(.artifactoryWatch(on: false, topic: nil, from: ids[0]))

    let graph = await store.graph
    #expect(errors.value.isEmpty)
    #expect(graph.nodes[id: ids[0]]?.artifactoryWatch == nil)
  }

  @Test
  func settingsRoundTripPinsTheRampBit() throws {
    var settings = GraphcodeSettings()
    settings.artifactoryEnabled = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(GraphcodeSettings.self, from: data).artifactoryEnabled)
  }

  @Test
  func briefingAnnouncesTheBoardOnlyWhileItIsOn() {
    let on = SessionBriefing.text(
      projectPath: "/tmp/p", settings: GraphcodeSettings(artifactoryEnabled: true))
    let off = SessionBriefing.text(
      projectPath: "/tmp/p", settings: GraphcodeSettings(artifactoryEnabled: false))
    #expect(on?.contains("## The Artifactory — notes for whoever comes next") == true)
    #expect(on?.contains("graphcode artifactory sync /tmp/p") == true)
    #expect(off?.contains("## The Artifactory") == false)
    // Off means byte-for-byte the pre-Artifactory briefing: no stray interpolation
    // line where the section would have gone.
    #expect(off?.contains("one-off.\n\n## Remembering across passes") == true)
  }

  @Test
  func wakeDigestRemindsAboutTheBoardOnlyWhileItIsOn() throws {
    let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("artifactory-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: baseURL) }
    let projectPath = "/tmp/digest"
    let nodeID = UUID()
    NodeMemory.append(
      "something happened", projectPath: projectPath, nodeID: nodeID, baseURL: baseURL)

    let on = NodeMemory.writeWakeDigest(
      projectPath: projectPath, nodeID: nodeID, artifactoryEnabled: true, baseURL: baseURL)
    #expect(on != nil)
    #expect(try String(contentsOf: try #require(on), encoding: .utf8).contains("Artifactory"))

    let off = NodeMemory.writeWakeDigest(
      projectPath: projectPath, nodeID: nodeID, artifactoryEnabled: false, baseURL: baseURL)
    #expect(
      !(try String(contentsOf: try #require(off), encoding: .utf8).contains("Mailboard")))
    #expect(
      !(try String(contentsOf: try #require(off), encoding: .utf8).contains("Artifactory")))
  }
}
