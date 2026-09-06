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

    let mailbox = await store.mailbox(MailboxQuery(selection: .board, fullBodies: true))
    #expect(mailbox.posts.map(\.body) == ["claiming #12"])
    #expect(mailbox.posts.map(\.topic) == ["claims"])
    #expect(mailbox.highestDeliveredID == 1)
    #expect(mailbox.digest == posted.boardDigest)
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
  }
}
