import MailroomKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The two budgets, the delete that keeps the note, the self-triaging sync, and the
/// ask that makes a resolving loop write something down — the review round that
/// followed the independent read of #229.
@Suite
struct MailroomBudgetTests {
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
      onAppendMemory: { nodeID, entry in memory?.withValue { $0.append((nodeID, entry)) } },
      onMailroomEnabled: { enabled })
    await store.handle(
      .createNode(NodeDraft(title: "Author", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(
      .createNode(NodeDraft(title: "Peer", loopType: .turnBased, firstInstruction: "Work")))
    return store
  }

  private func ids(_ store: GraphStore) async -> [UUID] {
    await store.graph.nodes.map(\.id)
  }

  // MARK: - Separate budgets

  /// The finding that started this round: a graph that merely talks used to evict every
  /// note on its board, because notes and mirrored records pruned from one pool.
  @Test
  func graphChatterCannotEvictANote() async {
    let store = await makeStore()
    let ids = await ids(store)

    await store.handle(
      .mailroomPost(text: "DEAD END: approach X fails", topic: "findings", from: ids[0]))
    for index in 0..<(Mailroom.maxLetters * 4) {
      await store.handle(
        .messageNode(ids[1], text: "ping \(index)", from: ids[0], followUp: true))
    }

    let board = await store.graph.mailroom
    #expect(board.contains { $0.body.contains("DEAD END") })
    #expect(board.filter { $0.kind == .letter }.count == Mailroom.maxLetters)
    #expect(board.filter { $0.kind == .notice }.count == 1)
  }

  /// And the converse: notes fill their own budget without evicting the records a loop
  /// joining mid-flight reads to catch up.
  @Test
  func notesCannotEvictTheRecords() async {
    let store = await makeStore()
    let ids = await ids(store)

    await store.handle(.messageNode(ids[1], text: "the API changed", from: ids[0], followUp: true))
    for index in 0..<(Mailroom.maxNotices + 10) {
      await store.handle(.mailroomPost(text: "note \(index)", topic: nil, from: ids[0]))
    }

    let board = await store.graph.mailroom
    #expect(board.filter { $0.kind == .letter }.count == 1)
    #expect(board.filter { $0.kind == .notice }.count == Mailroom.maxNotices)
    // Ids still only grow, so no cursor mistakes an old post for new mail.
    #expect(board.last?.id == Mailroom.maxNotices + 11)
  }

  @Test
  func pruningKeepsTheBoardInOneSequence() {
    let base = Date()
    var posts: [MailroomPost] = []
    for index in 1...(Mailroom.maxLetters + 4) {
      posts.append(
        MailroomPost(
          id: index, at: base, authorID: nil, author: "a human", topic: nil,
          body: "r\(index)", kind: .letter))
      posts.append(
        MailroomPost(
          id: index + 1000, at: base, authorID: nil, author: "a human", topic: nil,
          body: "n\(index)", kind: .notice))
    }
    let pruned = Mailroom.pruned(posts.sorted { $0.id < $1.id })
    #expect(pruned == pruned.sorted { $0.id < $1.id })
    #expect(pruned.filter { $0.kind == .letter }.count == Mailroom.maxLetters)
  }

  /// A board written before records had a kind decodes as all notes — everything on it
  /// was posted deliberately.
  @Test
  func postsSavedBeforeKindExistedDecodeAsNotes() throws {
    let json = """
      {"id":3,"at":747000000,"author":"Author","body":"hello"}
      """
    let post = try JSONDecoder().decode(MailroomPost.self, from: Data(json.utf8))
    #expect(post.kind == .notice)
    #expect(post.authorID == nil)
  }

  // MARK: - Deleting the author

  /// Deleting a loop used to erase what it had told every other loop. A board that
  /// un-says things is not a board: the note stays and the handle goes.
  @Test
  func deletingTheAuthorKeepsTheNoteAndTakesTheHandle() async {
    let store = await makeStore()
    let ids = await ids(store)
    await store.handle(
      .mailroomPost(text: "issue #12 is mine", topic: "claims", from: ids[0]))

    await store.handle(.deleteNode(ids[0]))

    let board = await store.graph.mailroom
    #expect(board.count == 1)
    #expect(board[0].body == "issue #12 is mine")
    #expect(board[0].authorID == nil)
    #expect(board[0].author == "Author (deleted)")
  }

  /// A loop created after the author is gone still finds the note — the property the
  /// whole feature exists for.
  @Test
  func aLoopBornAfterTheAuthorsDeletionStillReadsTheNote() async {
    let store = await makeStore()
    let ids = await ids(store)
    await store.handle(.mailroomPost(text: "approach X fails", topic: nil, from: ids[0]))
    await store.handle(.deleteNode(ids[0]))

    await store.handle(
      .createNode(NodeDraft(title: "Successor", loopType: .turnBased, firstInstruction: "W")))
    let graph = await store.graph
    let successor = graph.nodes.first { $0.title == "Successor" }!
    let unread = Mailroom.unread(
      in: graph.mailroom, since: successor.lastMailroomRead)
    #expect(unread.map(\.body) == ["approach X fails"])
  }

  /// Deleting a loop still takes its edges and memory — the note surviving is not a
  /// licence for the rest of the teardown to stop happening.
  @Test
  func deleteStillTearsDownEverythingElse() async throws {
    let removed = LockIsolated<[UUID]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onRemoveMemory: { nodeID in removed.withValue { $0.append(nodeID) } },
      onMailroomEnabled: { true })
    await store.handle(
      .createNode(NodeDraft(title: "Author", loopType: .turnBased, firstInstruction: "W")))
    let id = try #require(await store.graph.nodes.first?.id)
    await store.handle(.mailroomPost(text: "a note", topic: nil, from: id))

    await store.handle(.deleteNode(id))

    #expect(removed.value == [id])
    #expect(await store.graph.nodes.isEmpty)
    #expect(await store.graph.mailroom.count == 1)
  }

  // MARK: - Self-triaging sync

  @Test
  func aLargeBacklogRendersAsHeadlinesAndSaysSo() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"))
    let reader = LoopNode(title: "Reader", loopType: .turnBased)
    graph.nodes.append(reader)
    for index in 1...(Mailroom.triageAfterPosts + 1) {
      graph.mailroom.append(
        MailroomPost(
          id: index, at: Date(), authorID: nil, author: "a human", topic: nil,
          body: "note \(index) with a body long enough to be worth truncating for triage"))
    }

    let rendered = GraphcodeCommand.renderMailroom(
      graph, unreadFor: reader.id, autoTriage: true)

    #expect(rendered.contains("headlines only"))
    #expect(rendered.contains("mail read /tmp/p <post-id>"))
  }

  @Test
  func aSmallBacklogStillPrintsEveryBody() {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"))
    let reader = LoopNode(title: "Reader", loopType: .turnBased)
    graph.nodes.append(reader)
    graph.mailroom.append(
      MailroomPost(
        id: 1, at: Date(), authorID: nil, author: "a human", topic: nil,
        body: "short enough to read in full"))

    let rendered = GraphcodeCommand.renderMailroom(
      graph, unreadFor: reader.id, autoTriage: true)

    #expect(rendered.contains("short enough to read in full"))
    #expect(!rendered.contains("headlines only"))
  }

  /// Bytes, not just count: a handful of kilobyte notes is the same problem as forty
  /// short ones.
  @Test
  func aFewVeryLongNotesTriageOnBytes() {
    let posts = (1...5).map { index in
      MailroomPost(
        id: index, at: Date(), authorID: nil, author: "a human", topic: nil,
        body: String(repeating: "x", count: 1000))
    }
    #expect(Mailroom.needsTriage(posts))
    #expect(!Mailroom.needsTriage(Array(posts.prefix(1))))
  }

  @Test
  func syncParsesFullAndDefaultsToAutoTriage() throws {
    let full = try GraphcodeCommand.parse(["mailroom", "sync", "/tmp/p", "--full"])
    #expect(
      full
        == .mailroomInbox(
          projectPath: "/tmp/p", headlines: false, mark: false, json: false, full: true))
    let plain = try GraphcodeCommand.parse(["mailroom", "sync", "/tmp/p"])
    #expect(
      plain
        == .mailroomInbox(
          projectPath: "/tmp/p", headlines: false, mark: false, json: false, full: false))
  }

  // MARK: - The write-side pull

  /// Every other mailroom affordance is read-side. This is the one that asks a loop
  /// to write, at the one moment it knows what it learned.
  @Test
  func aResolvingLoopIsAskedToLeaveANote() {
    let ask = MessageBus.resolutionAsk(distillSkill: false, mailroomProjectPath: "/tmp/p")
    #expect(ask?.contains("graphcode mail post /tmp/p") == true)
    #expect(ask?.hasPrefix("[graphcode] ") == true)
  }

  /// A goal loop that succeeded is owed both asks, and is interrupted once for them.
  @Test
  func bothAsksArriveAsOneInterruption() {
    let ask = MessageBus.resolutionAsk(distillSkill: true, mailroomProjectPath: "/tmp/p")
    #expect(ask?.contains("distill it into a project skill") == true)
    #expect(ask?.contains("graphcode mail post") == true)
    #expect(ask?.components(separatedBy: "[graphcode] ").count == 2)
  }

  @Test
  func noBoardAndNoSkillMeansNoInterruption() {
    #expect(MessageBus.resolutionAsk(distillSkill: false, mailroomProjectPath: nil) == nil)
  }

  /// With the board off, a resolving loop is never pointed at a verb the daemon would
  /// refuse.
  @Test
  func theAskIsGatedWithTheRestOfTheBoard() async throws {
    let delivered = LockIsolated<[(UUID, String)]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { node, message, _ in
        delivered.withValue { $0.append((node.id, message)) }
        return true
      },
      onMailroomEnabled: { false })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "CI passes"))))
    let id = try #require(await store.graph.nodes.first?.id)

    await store.handle(.nodeCheckApproved(id))

    #expect(!delivered.value.contains { $0.1.contains("mail post") })
  }
}
