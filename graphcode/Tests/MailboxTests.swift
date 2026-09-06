import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// The room's read path since issue #288: a `.graphChanged` carries the room's digest,
/// never its posts, and a client that wants posts asks for exactly the posts it wants
/// with a `DaemonCommand.mailbox`. These pin the three halves — what the snapshot says
/// instead, what the room answers, and that the answer is what leaves the daemon.
@Suite
struct MailboxTests {
  private static func post(
    _ id: Int, _ body: String, author: String = "a human", authorID: UUID? = nil,
    topic: String? = nil, kind: MailroomPost.Kind = .notice
  ) -> MailroomPost {
    MailroomPost(
      id: id, at: Date(timeIntervalSince1970: TimeInterval(id)), authorID: authorID,
      author: author, topic: topic, body: body, kind: kind)
  }

  /// A room of three and a reader who has seen the first.
  private static func room() -> (LoopGraph, LoopNode) {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastMailroomRead = 1
    graph.nodes.append(reader)
    graph.mailroom = [
      post(1, "already read"),
      post(
        2, String(repeating: "red ", count: 40), author: "Author", authorID: UUID(),
        topic: "build"),
      post(3, "auth deadlock traced to token refresh"),
    ]
    return (graph, reader)
  }

  private func serve(
    _ graph: LoopGraph, _ selection: MailboxQuery.Selection, search: String? = nil,
    fullBodies: Bool? = nil
  ) -> Mailbox {
    Mailroom.serve(
      MailboxQuery(selection: selection, search: search, fullBodies: fullBodies),
      from: graph.mailroom
    ) { graph.nodes[id: $0]?.lastMailroomRead }
  }

  // MARK: The snapshot

  @Test
  func aWireSnapshotCarriesTheDigestInsteadOfThePosts() throws {
    let (graph, _) = Self.room()

    let wire = graph.wireSnapshot()
    #expect(wire.mailroom.isEmpty)
    #expect(wire.mailroomDigest == MailroomDigest(of: graph.mailroom))
    #expect(wire.boardDigest.count == 3)
    #expect(wire.boardDigest.latestID == 3)
    // Everything that is not the room is the graph exactly as it was.
    #expect(wire.nodes == graph.nodes)
    #expect(wire.project == graph.project)

    // The digest survives the socket; the posts were never on it.
    let decoded = try JSONDecoder().decode(
      LoopGraph.self, from: try JSONEncoder().encode(wire))
    #expect(decoded.mailroom.isEmpty)
    #expect(decoded.mailroomDigest == wire.mailroomDigest)
    // And a graph the daemon owns never carries one to disk.
    #expect(graph.mailroomDigest == nil)
    let persisted = String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
    #expect(!persisted.contains("mailroomDigest"))
  }

  /// A snapshot from a daemon that still ships posts — or the daemon's own graph —
  /// describes its room off those posts, so every reader of `boardDigest` works on
  /// both sides of the upgrade.
  @Test
  func aGraphStillCarryingPostsDescribesItselfOffThem() {
    let (graph, _) = Self.room()
    #expect(graph.boardDigest == graph.wireSnapshot().boardDigest)
    #expect(LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x")).boardDigest.isEmpty)
  }

  /// The one edit that changes a room without changing what it holds — an author's
  /// deletion — has to show in the digest, or a client's copy would keep naming a loop
  /// that is gone. Pruning and posting already move `count` or `latestID`.
  @Test
  func theFingerprintSeesAnAuthorsDeletion() {
    let (graph, _) = Self.room()
    var edited = graph
    edited.mailroom[1] = graph.mailroom[1].withAuthorDeleted()

    let before = MailroomDigest(of: graph.mailroom)
    let after = MailroomDigest(of: edited.mailroom)
    #expect(before.count == after.count && before.latestID == after.latestID)
    #expect(before.fingerprint != after.fingerprint)
    // Deterministic: the same room describes itself the same way twice, and across
    // processes — it is compared between a daemon's snapshots either side of a restart.
    #expect(MailroomDigest(of: graph.mailroom) == before)
  }

  // MARK: The answer

  @Test
  func unreadIsWhatTheCursorHasNotCoveredAndAStrangerSeesEverything() {
    let (graph, reader) = Self.room()

    let mine = serve(graph, .unread(reader: reader.id))
    #expect(mine.posts.map(\.id) == [2, 3])
    #expect(mine.lastRead == 1)
    #expect(mine.highestDeliveredID == 3)
    #expect(mine.digest.count == 3)

    // No cursor to subtract from: shown everything, as before — the cursor advance
    // that follows is what refuses a reader the graph does not know.
    let stranger = serve(graph, .unread(reader: UUID()))
    #expect(stranger.posts.map(\.id) == [1, 2, 3])
    #expect(stranger.lastRead == nil)
  }

  @Test
  func theBoardAndOnePostAreWholeAndSearchFiltersBeforeAnyCut() {
    let (graph, reader) = Self.room()

    #expect(serve(graph, .board, fullBodies: true).posts == graph.mailroom)
    #expect(serve(graph, .post(id: 2)).posts == [graph.mailroom[1]])
    #expect(serve(graph, .post(id: 9)).posts.isEmpty)
    #expect(serve(graph, .post(id: 9)).highestDeliveredID == nil)

    // "deadlock" lives only in #3's body; "auth" would also match #2's author.
    #expect(serve(graph, .unread(reader: reader.id), search: "deadlock").posts.map(\.id) == [3])
    #expect(serve(graph, .board, search: "AUTH").posts.map(\.id) == [2, 3])
    #expect(serve(graph, .board, search: "nonesuch").posts.isEmpty)
  }

  /// The bound. Left to the room, a backlog past `Mailroom.needsTriage` comes back as
  /// headlines and says so; a caller can insist either way; a deep read never cuts.
  @Test
  func aBacklogIsTriagedToHeadlinesUnlessTheCallerInsists() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.mailroom = (1...(Mailroom.triageAfterPosts + 1)).map {
      Self.post($0, String(repeating: "x", count: 200))
    }
    let reader = UUID()

    let triaged = serve(graph, .unread(reader: reader))
    #expect(triaged.bodiesTrimmed)
    #expect(triaged.posts.allSatisfy { $0.body.count == Mailroom.headlineBodyBudget })
    #expect(triaged.posts.count == graph.mailroom.count)
    #expect(triaged.highestDeliveredID == graph.mailroom.count)

    let insisted = serve(graph, .unread(reader: reader), fullBodies: true)
    #expect(!insisted.bodiesTrimmed)
    #expect(insisted.posts == graph.mailroom)

    var small = graph
    small.mailroom = [Self.post(1, "short")]
    let headlines = serve(small, .board, fullBodies: false)
    #expect(headlines.bodiesTrimmed)
    #expect(headlines.posts[0].body == "short")

    // Bodies cut in characters, never mid-glyph, and short ones untouched.
    let accented = Self.post(1, String(repeating: "é", count: 100))
    #expect(accented.headlined().body == String(repeating: "é", count: 80))
    #expect(Self.post(2, "brief").headlined() == Self.post(2, "brief"))

    #expect(!serve(graph, .post(id: 1)).bodiesTrimmed)
    #expect(serve(graph, .post(id: 1)).posts[0].body.count == 200)
  }

  /// The bound with teeth: an unread answer is a page, oldest first, and says how many
  /// it left; the whole room and a deep read are never paged.
  @Test
  func anUnreadAnswerIsAPageThatSaysWhatItLeft() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.mailroom = (1...(Mailroom.inboxPageSize + 50)).map { Self.post($0, "note \($0)") }
    let reader = UUID()

    let page = serve(graph, .unread(reader: reader), fullBodies: true)
    #expect(page.posts.count == Mailroom.inboxPageSize)
    #expect(page.posts.first?.id == 1)
    #expect(page.highestDeliveredID == Mailroom.inboxPageSize)
    #expect(page.remaining == 50)

    #expect(serve(graph, .board).posts.count == graph.mailroom.count)
    #expect(serve(graph, .board).remaining == 0)
    #expect(serve(graph, .post(id: 7)).remaining == 0)
  }

  /// `highestDeliveredID` names only mail that was handed over, in every shape: an
  /// empty page has none; a page's edge is its last post only when nothing below it
  /// was skipped; a search that skipped the first unread post promises nothing, and
  /// one that matched a prefix promises exactly that prefix. The reviewer's case from
  /// #293 is the third.
  @Test
  func theCursorCeilingNeverPassesMailThatWasNotHandedOver() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    graph.mailroom = [
      Self.post(1, "nothing to do with it"),
      Self.post(2, "also unrelated"),
      Self.post(3, "the release is cut"),
    ]
    let reader = LoopNode(title: "Reader", loopType: .turnBased)
    graph.nodes.append(reader)

    let searched = serve(graph, .unread(reader: reader.id), search: "release")
    #expect(searched.posts.map(\.id) == [3])
    #expect(searched.highestDeliveredID == nil)

    var caughtUp = graph
    caughtUp.nodes[id: reader.id]?.lastMailroomRead = 3
    #expect(serve(caughtUp, .unread(reader: reader.id)).highestDeliveredID == nil)

    // A search that matches the first two and not the third may promise #2.
    var prefix = graph
    prefix.mailroom = [Self.post(1, "release a"), Self.post(2, "release b"), Self.post(3, "other")]
    #expect(serve(prefix, .unread(reader: reader.id), search: "release").highestDeliveredID == 2)

    // A page promises its own edge, and nothing on the next page.
    var long = graph
    long.mailroom = (1...(Mailroom.inboxPageSize + 1)).map { Self.post($0, "note \($0)") }
    let page = serve(long, .unread(reader: reader.id))
    #expect(page.highestDeliveredID == Mailroom.inboxPageSize)
    #expect(page.remaining == 1)

    // The whole room and a deep read: what was handed over is what was asked for.
    #expect(serve(graph, .board, search: "release").highestDeliveredID == 3)
    #expect(serve(graph, .post(id: 2)).highestDeliveredID == 2)
  }

  /// A page is never smaller than the room, or pruning could eat page two between two
  /// requests and the reader would skip it in silence — the window the unbounded
  /// answer never had. And what pruning does eat is counted, not hidden.
  @Test
  func aPageIsNeverSmallerThanTheRoomAndPrunedMailIsCounted() {
    #expect(Mailroom.inboxPageSize >= Mailroom.maxNotices + Mailroom.maxLetters)

    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    var reader = LoopNode(title: "Reader", loopType: .turnBased)
    reader.lastMailroomRead = 2
    graph.nodes.append(reader)
    // Ids 3 and 4 landed after the cursor and were pruned; 5 survives.
    graph.mailroom = [Self.post(1, "old"), Self.post(2, "read"), Self.post(5, "new")]

    let answer = serve(graph, .unread(reader: reader.id))
    #expect(answer.posts.map(\.id) == [5])
    #expect(answer.prunedUnread == 2)
    #expect(answer.highestDeliveredID == 5)

    // Caught up, and everything since was pruned: told so, with nothing to hand over.
    var emptied = graph
    emptied.mailroom = [Self.post(1, "old"), Self.post(2, "read")]
    emptied.nodes[id: reader.id]?.lastMailroomRead = 2
    var latestGone = emptied
    latestGone.mailroom.append(Self.post(9, "much later"))
    latestGone.nodes[id: reader.id]?.lastMailroomRead = 9
    #expect(serve(latestGone, .unread(reader: reader.id)).prunedUnread == 0)
    #expect(serve(graph, .board).prunedUnread == 0)
    #expect(serve(graph, .unread(reader: UUID())).prunedUnread == 0)
  }

  /// `remaining` decodes as zero from an answer that predates it.
  @Test
  func anOlderAnswerDecodesWithNothingRemaining() throws {
    let literal = """
      {"posts":[],"bodiesTrimmed":false,"digest":{"count":0,"latestID":0,"fingerprint":1}}
      """
    let decoded = try JSONDecoder().decode(Mailbox.self, from: Data(literal.utf8))
    #expect(decoded.remaining == 0)
    #expect(decoded.posts.isEmpty)
  }

  /// The wire shape the remote shim types by hand: pinned here so a rename on the Swift
  /// side fails a test before it fails on someone's build box.
  @Test
  func theQueryAndItsAnswerHaveTheShapeTheShimTypes() throws {
    let reader = UUID()
    let literal = """
      {"mailbox":{"projectPath":"/tmp/x","query":{"selection":{"unread":{"reader":\
      "\(reader.uuidString)"}},"fullBodies":true}}}
      """
    let decoded = try JSONDecoder().decode(DaemonCommand.self, from: Data(literal.utf8))
    #expect(
      decoded
        == .mailbox(
          projectPath: "/tmp/x",
          query: MailboxQuery(selection: .unread(reader: reader), fullBodies: true)))
    let board = try JSONDecoder().decode(
      DaemonCommand.self,
      from: Data(#"{"mailbox":{"projectPath":"/tmp/x","query":{"selection":{"board":{}}}}}"#.utf8))
    #expect(board == .mailbox(projectPath: "/tmp/x", query: MailboxQuery(selection: .board)))

    let answer = DaemonEvent.mailbox(
      projectPath: "/tmp/x",
      mailbox: Mailbox(
        posts: [], bodiesTrimmed: false, digest: MailroomDigest(of: []), lastRead: 4,
        highestDeliveredID: nil))
    let encoded = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(answer))
    let envelope = try #require((encoded as? [String: Any])?["mailbox"] as? [String: Any])
    #expect(envelope["projectPath"] as? String == "/tmp/x")
    let mailbox = try #require(envelope["mailbox"] as? [String: Any])
    #expect(mailbox["lastRead"] as? Int == 4)
    #expect(mailbox["bodiesTrimmed"] as? Bool == false)
    #expect((mailbox["digest"] as? [String: Any])?["count"] as? Int == 0)
  }
}

/// The daemon half, in an extension: the suite sits past swiftlint's 350-line
/// `type_body_length` error with it inside.
extension MailboxTests {
  // MARK: The daemon

  /// Reads one frame off `descriptor` on another thread: the store writes from its
  /// actor, and a full socket buffer would otherwise park the actor the test awaits.
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

  /// Over a real socket: the snapshot a client joins with and the broadcast a post
  /// causes carry the digest and no posts, and the store's mailbox is where they are.
  @Test
  func broadcastsCarryTheDigestAndTheMailboxCarriesThePosts() async throws {
    let store = GraphStore(
      onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true },
      onMailroomEnabled: { true })
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      close(pair[0])
      close(pair[1])
    }

    await store.addConnection(id: UUID(), fileDescriptor: pair[0])
    guard case .graphChanged(let joined) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the joining snapshot")
      return
    }
    #expect(joined.boardDigest.isEmpty)
    #expect(joined.mailroomDigest != nil)

    await store.handle(.mailroomPost(text: "claiming #12", topic: "Claims", from: nil))
    guard case .graphChanged(let posted) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the broadcast the post caused")
      return
    }
    #expect(posted.mailroom.isEmpty)
    #expect(posted.boardDigest.count == 1)
    #expect(posted.boardDigest.latestID == 1)

    let mailbox = try await store.mailbox(MailboxQuery(selection: .board, fullBodies: true))
    #expect(mailbox.posts.map(\.body) == ["claiming #12"])
    #expect(mailbox.posts.map(\.topic) == ["claims"])
    #expect(mailbox.highestDeliveredID == 1)
    #expect(mailbox.digest == posted.boardDigest)
  }

  /// The cursor moves to the highest post handed over, inside the same actor turn as
  /// the answer — and since a page is never smaller than the room, one answer hands
  /// over every live unread post. Persisted once per advance, never broadcast: the
  /// connection that asked gets its mailbox and no snapshot.
  @Test
  func advancingTheCursorStopsAtWhatWasHandedOver() async throws {
    let persisted = LockIsolated(0)
    let store = GraphStore(
      onGraphChanged: { _ in persisted.withValue { $0 += 1 } },
      onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true },
      onMailroomEnabled: { true })
    await store.handle(
      .createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    let reader = await store.graph.nodes[0].id
    // More than the room keeps: the oldest five are pruned before anyone reads.
    for index in 1...(Mailroom.maxNotices + 5) {
      await store.handle(.mailroomPost(text: "note \(index)", topic: nil, from: nil))
    }
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      OutboundChannels.close(pair[0])
      close(pair[1])
    }
    await store.addConnection(id: UUID(), fileDescriptor: pair[0])
    guard case .graphChanged = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the joining snapshot")
      return
    }
    let writesBefore = persisted.value

    let first = try await store.mailbox(
      MailboxQuery(selection: .unread(reader: reader), fullBodies: true, advanceCursor: true))
    #expect(first.posts.count == Mailroom.maxNotices)
    #expect(first.posts.first?.id == 6)
    #expect(first.remaining == 0)
    #expect(first.highestDeliveredID == Mailroom.maxNotices + 5)
    #expect(await store.graph.nodes[id: reader]?.lastMailroomRead == Mailroom.maxNotices + 5)
    #expect(persisted.value == writesBefore + 1)

    // Caught up: nothing handed over, nothing moved, nothing written.
    let second = try await store.mailbox(
      MailboxQuery(selection: .unread(reader: reader), advanceCursor: true))
    #expect(second.posts.isEmpty)
    #expect(second.highestDeliveredID == nil)
    #expect(persisted.value == writesBefore + 1)

    // One more lands and is handed over on the next ask, moving the cursor by one.
    await store.handle(.mailroomPost(text: "late", topic: nil, from: nil))
    let third = try await store.mailbox(
      MailboxQuery(selection: .unread(reader: reader), advanceCursor: true))
    #expect(third.posts.map(\.id) == [Mailroom.maxNotices + 6])
    #expect(await store.graph.nodes[id: reader]?.lastMailroomRead == Mailroom.maxNotices + 6)

    // No snapshot went out for any advance — only the post's own broadcast.
    guard case .graphChanged = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the late post's broadcast")
      return
    }
    var probe = [UInt8](repeating: 0, count: 1)
    let peeked = recv(pair[1], &probe, 1, MSG_PEEK | MSG_DONTWAIT)
    #expect(peeked < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
  }

  /// A reader the graph does not know, or a room that is off, is refused the advance
  /// — to the asker alone, with the cursor untouched — and a read that asked for no
  /// advance is never refused.
  @Test
  func theAdvanceIsRefusedWhereTheOldCursorCommandWas() async throws {
    let store = GraphStore(
      onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true },
      onMailroomEnabled: { false })
    await store.handle(
      .createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    let reader = await store.graph.nodes[0].id

    await #expect(throws: GraphStore.MailboxRefusal.self) {
      try await store.mailbox(
        MailboxQuery(selection: .unread(reader: reader), advanceCursor: true))
    }
    _ = try await store.mailbox(MailboxQuery(selection: .unread(reader: reader)))
    _ = try await store.mailbox(MailboxQuery(selection: .board, advanceCursor: true))

    let on = GraphStore(
      onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true },
      onMailroomEnabled: { true })
    await #expect(throws: GraphStore.MailboxRefusal.self) {
      try await on.mailbox(
        MailboxQuery(selection: .unread(reader: UUID()), advanceCursor: true))
    }
  }

  /// The registry answers a mailbox request on the asking connection alone, names the
  /// project canonically, and refuses one against a project the connection never opened
  /// the way it refuses a command against it.
  @Test
  func theRegistryRoutesAMailboxRequestLikeACommand() async throws {
    let project = "/tmp/mailbox-tests-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: project) }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let registry = ProjectRegistry(
      persistenceDirectory: directory, ensureSession: { _, _ in }, readPresence: nil)
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      close(pair[0])
      close(pair[1])
    }

    let connection = UUID()
    await registry.addConnection(id: connection, fileDescriptor: pair[0])
    await registry.handle(.openProject(path: project), connectionID: connection)
    guard case .graphChanged = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the joining snapshot")
      return
    }

    await registry.handle(
      .mailbox(projectPath: project, query: MailboxQuery(selection: .board)),
      connectionID: connection)
    guard case .mailbox(let path, let mailbox) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the mailbox answer")
      return
    }
    #expect(path == ProjectRegistry.canonicalize(project))
    #expect(mailbox.posts.isEmpty)
    #expect(mailbox.digest.isEmpty)

    await registry.handle(
      .mailbox(projectPath: "/tmp", query: MailboxQuery(selection: .board)),
      connectionID: connection)
    guard case .errorOccurred(let refusal) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected a refusal")
      return
    }
    #expect(refusal.contains("isn't open"))

    // A refused cursor advance comes back the same way, to this connection.
    await registry.handle(
      .mailbox(
        projectPath: project,
        query: MailboxQuery(selection: .unread(reader: UUID()), advanceCursor: true)),
      connectionID: connection)
    guard case .errorOccurred(let refusedAdvance) = try await nextEvent(from: pair[1]) else {
      Issue.record("expected the advance to be refused")
      return
    }
    #expect(refusedAdvance.contains("loop identity") || refusedAdvance.contains("Mailroom is off"))
  }
}
