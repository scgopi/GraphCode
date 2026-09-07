import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// Issue #304: the drain of staged follow-ups runs across awaits and the presence poll
/// re-enters it every fifteen seconds. Two drains overlapping delivered the same items
/// twice and the later one's bookkeeping overwrote the earlier's — mail duplicated, mail
/// lost, mail out of order. And `mail watch --off` left the wakes already staged to
/// arrive anyway, past the reader's cursor.
@Suite
struct FollowUpDrainTests {
  /// What the target's session appears to be doing; the drain asks each time.
  private actor Readings {
    var presence: Presence = .busy
    var delay: Duration = .zero
    func set(_ presence: Presence, delay: Duration = .zero) {
      self.presence = presence
      self.delay = delay
    }
    func read() async -> PresenceReading {
      if delay > .zero { try? await Task.sleep(for: delay) }
      return PresenceReading(presence: presence, confidence: .reported)
    }
  }

  /// A connection with a channel lifecycle of its own and a reader draining it: a bare
  /// `/dev/null` descriptor can be dropped as "disconnected" when its number is reused
  /// across the suite, and then the poll never drains.
  private final class Attachment: @unchecked Sendable {
    let daemonEnd: Int32
    private let peer: Int32
    private let drainer: Task<Void, Never>
    init() {
      var pair: [Int32] = [0, 0]
      _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
      daemonEnd = pair[0]
      peer = pair[1]
      let reading = pair[1]
      drainer = Task.detached {
        var sink = [UInt8](repeating: 0, count: 65536)
        while recv(reading, &sink, sink.count, 0) > 0 {}
      }
    }
    deinit {
      OutboundChannels.close(daemonEnd)
      close(peer)
      drainer.cancel()
    }
  }

  private func makeStore(
    readings: Readings, delivered: LockIsolated<[String]>, attachment: Attachment
  ) async -> (GraphStore, target: UUID, sender: UUID) {
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { _, _ in await readings.read() },
      onMailroomEnabled: { true })
    await store.handle(
      .createNode(NodeDraft(title: "Target", loopType: .turnBased, firstInstruction: "Work")))
    await store.handle(
      .createNode(NodeDraft(title: "Sender", loopType: .turnBased, firstInstruction: "Work")))
    let ids = await store.graph.nodes.map(\.id)
    // A connection, so the presence poll runs.
    await store.addConnection(id: UUID(), fileDescriptor: attachment.daemonEnd)
    // Start the poll once so the target carries a `busy` reading: that is what stages a
    // follow-up instead of typing it in.
    await store.pollPresence()
    return (store, ids[0], ids[1])
  }

  @Test
  func overlappingDrainsDeliverEachMessageOnceAndLoseNothing() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    for index in 1...3 {
      await store.handle(
        .messageNode(target, text: "staged \(index)", from: sender, followUp: true))
    }
    #expect(delivered.value.isEmpty)

    // Idle now, and slow to answer, so a second poll lands while the first drain is
    // suspended mid-delivery — the overlap that duplicated and dropped mail.
    await readings.set(.idle, delay: .milliseconds(40))
    async let first: Void = store.pollPresence()
    try? await Task.sleep(for: .milliseconds(20))
    async let second: Void = store.pollPresence()
    // And one more staged while both are in flight: it must survive the overlap.
    try? await Task.sleep(for: .milliseconds(10))
    await store.handle(.messageNode(target, text: "staged late", from: sender, followUp: true))
    _ = await (first, second)
    await store.pollPresence()

    let texts = delivered.value.map {
      $0.replacingOccurrences(of: "[graphcode] Sender: ", with: "")
    }
    #expect(texts.filter { $0 == "staged 1" }.count == 1)
    #expect(texts.filter { $0 == "staged 2" }.count == 1)
    #expect(texts.filter { $0 == "staged 3" }.count == 1)
    #expect(texts.filter { $0 == "staged late" }.count == 1)
    #expect(Array(texts.prefix(3)) == ["staged 1", "staged 2", "staged 3"])
  }

  @Test
  func watchOffDropsStagedWakesButNotAPeersFollowUp() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    await store.handle(.mailroomWatch(on: true, topic: nil, from: target))
    await store.handle(
      .mailroomPost(text: "a post the watcher will be woken for", topic: nil, from: sender))
    await store.handle(.messageNode(target, text: "a peer's word", from: sender, followUp: true))
    #expect(delivered.value.isEmpty)

    await store.handle(.mailroomWatch(on: false, topic: nil, from: target))
    await readings.set(.idle)
    await store.pollPresence()

    #expect(delivered.value.count == 1)
    #expect(delivered.value.first?.contains("a peer's word") == true)
    #expect(!delivered.value.contains { $0.contains("new post #") })
  }

  @Test
  func aWakeForAPostAlreadyReadIsNotSent() async throws {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    await store.handle(.mailroomWatch(on: true, topic: nil, from: target))
    await store.handle(
      .mailroomPost(text: "read before the wake could land", topic: nil, from: sender))
    // The watcher reads its inbox — the cursor passes the post — before it goes idle.
    _ = try await store.mailbox(
      MailboxQuery(selection: .unread(reader: target), advanceCursor: true))
    await readings.set(.idle)
    await store.pollPresence()

    #expect(delivered.value.isEmpty)
  }
}
