import Foundation
import GraphcodeKit
import MailroomKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// Independent review probes for PR #295 (issue #288), written against the rule the PR
/// states in its own words: a cursor moves only through mail that was handed over.
/// Each names a shape the PR's own tests do not cover.
@Suite
struct MailboxCursorReviewTests {
  private func makeStore(on roomIsOn: Bool = true) -> GraphStore {
    GraphStore(
      onEnsureSession: { _, _ in }, onDeliverMessage: { _, _, _ in true },
      onMailroomEnabled: { roomIsOn })
  }

  private func makeReader(in store: GraphStore) async -> UUID {
    await store.handle(
      .createNode(NodeDraft(title: "Reader", loopType: .turnBased, firstInstruction: "Work")))
    return await store.graph.nodes.last!.id
  }

  /// Blocking read with a deadline. `OutboundChannels` writes off the actor, so a
  /// `MSG_DONTWAIT` read straight after `handle` races the delivery and reads empty —
  /// which looks exactly like "nothing was broadcast".
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

  // MARK: The fixes this PR claims

  /// The landmine from the #293 review: `search` + `advanceCursor` in one request. The
  /// pair survives the wire, so the guard has to be the daemon's, not a caller's.
  @Test
  func aSearchedInboxIsRefusedAndMovesNothing() async throws {
    let store = makeStore()
    let reader = await makeReader(in: store)
    for index in 1...10 {
      await store.handle(
        .mailroomPost(text: index == 10 ? "needle" : "hay \(index)", topic: nil, from: nil))
    }

    let wire = try JSONEncoder().encode(
      MailboxQuery(selection: .unread(reader: reader), search: "needle", advanceCursor: true))
    let decoded = try JSONDecoder().decode(MailboxQuery.self, from: wire)
    #expect(decoded.search == "needle" && decoded.advanceCursor == true)

    await #expect(throws: GraphStore.MailboxRefusal.self) { try await store.mailbox(decoded) }
    #expect(await store.graph.nodes[id: reader]?.lastMailroomRead == nil)
    let after = try await store.mailbox(MailboxQuery(selection: .unread(reader: reader)))
    #expect(after.posts.count == 10)
  }

  /// `highestDeliveredID` must be honest in every answer shape, including one the PR's
  /// own tests do not build: a room pruned out from under a reader whose cursor sits
  /// below what survived.
  @Test
  func highestDeliveredIDIsHonestInEveryShape() async throws {
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x"))
    let node = LoopNode(title: "Reader", loopType: .turnBased)
    graph.nodes.append(node)
    graph.mailroom = (1...20).map {
      MailroomPost(
        id: $0, at: Date(timeIntervalSince1970: TimeInterval($0)), authorID: nil,
        author: "a human", topic: nil, body: $0 == 20 ? "needle" : "hay")
    }
    func serve(_ query: MailboxQuery, cursor: Int?) -> Mailbox {
      Mailroom.serve(query, from: graph.mailroom) { _ in cursor }
    }
    let unread = MailboxQuery.Selection.unread(reader: node.id)

    // A search that skips the first unread post may not name anything.
    #expect(
      serve(MailboxQuery(selection: unread, search: "needle"), cursor: nil).highestDeliveredID
        == nil)
    // Empty answers, caught up and past the end.
    #expect(serve(MailboxQuery(selection: unread), cursor: 20).highestDeliveredID == nil)
    #expect(serve(MailboxQuery(selection: unread), cursor: 10_000).highestDeliveredID == nil)
    // The whole surviving room, in one answer, with nothing left over.
    let whole = serve(MailboxQuery(selection: unread, fullBodies: true), cursor: nil)
    #expect(whole.posts.count == 20 && whole.remaining == 0 && whole.highestDeliveredID == 20)

    // Pruned under the reader: ids 1...5 gone, cursor still at 2. What survives is what
    // may be promised, and the gap is reported rather than passed over in silence.
    graph.mailroom = Array(graph.mailroom.dropFirst(5))
    let afterPrune = serve(MailboxQuery(selection: unread, fullBodies: true), cursor: 2)
    #expect(afterPrune.posts.map(\.id) == Array(6...20))
    #expect(afterPrune.highestDeliveredID == 20)
    #expect(afterPrune.prunedUnread == 3, "posts #3...#5 were pruned before this reader read")
  }

  /// The page must never be smaller than what the room can hold, or a backlog strands
  /// on page two and is pruned before the reader asks for it.
  @Test
  func onePageAlwaysHoldsEverythingTheRoomCanKeep() async throws {
    #expect(Mailroom.inboxPageSize >= Mailroom.maxNotices + Mailroom.maxLetters)

    let store = makeStore()
    let reader = await makeReader(in: store)
    for index in 1...(Mailroom.maxNotices + 150) {
      await store.handle(.mailroomPost(text: "note \(index)", topic: nil, from: nil))
    }
    let answer = try await store.mailbox(
      MailboxQuery(selection: .unread(reader: reader), fullBodies: true, advanceCursor: true))
    #expect(answer.posts.count == Mailroom.maxNotices)
    #expect(answer.remaining == 0, "a live room must never strand unread mail on page two")
    #expect(await store.graph.nodes[id: reader]?.lastMailroomRead == answer.posts.last?.id)
  }

  // MARK: What the fixes did not cover

  /// The legacy `mailroomInbox` refusal goes out through `announceError`, which writes to
  /// EVERY connected client — the broadcast this PR moved the mailbox refusal off. So one
  /// stale CLI's `mail inbox` lands an error on the running app and on every other CLI
  /// parked in `waitForEvent { .graphChanged, .errorOccurred }`, which calls `fail()` on
  /// it: an unrelated `mail post` or `node memo` dies with someone else's upgrade notice.
  @Test
  func theLegacyRefusalMustNotBeBroadcastToBystanders() async throws {
    let store = makeStore()
    let reader = await makeReader(in: store)
    var asker: [Int32] = [0, 0]
    var bystander: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &asker) == 0)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &bystander) == 0)
    defer {
      for descriptor in [asker[0], asker[1], bystander[0], bystander[1]] { close(descriptor) }
    }
    await store.addConnection(id: UUID(), fileDescriptor: asker[0])
    await store.addConnection(id: UUID(), fileDescriptor: bystander[0])
    guard case .graphChanged = try nextEvent(from: asker[1]),
      case .graphChanged = try nextEvent(from: bystander[1])
    else {
      Issue.record("expected each connection's joining snapshot")
      return
    }

    await store.handle(.mailroomInbox(from: reader))

    var reached: [String] = []
    while let event = try nextEvent(from: bystander[1], waiting: 1) {
      if case .errorOccurred(let message) = event { reached.append(message) }
    }
    #expect(
      reached.isEmpty,
      Comment(rawValue: "a bystander connection was told \(reached) — every parked CLI fails"))
  }
}
