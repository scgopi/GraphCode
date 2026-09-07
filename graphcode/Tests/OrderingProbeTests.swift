import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// Issue #304, ordering half. #309 fixed duplicates and loss; these three probes
/// characterise what it did not fix. Each is deterministic — the presence readings are
/// scripted, so a failure here is a defect, not a race that happened to land.
@Suite
struct OrderingProbeTests {
  /// Answers each presence read from a script, so a turn can end at an exact point in
  /// one drain's walk over its batch.
  private actor ScriptedReadings {
    private var script: [Presence]
    private var index = 0
    private(set) var reads = 0
    init(_ script: [Presence]) { self.script = script }
    func read() -> PresenceReading {
      reads += 1
      let presence = index < script.count ? script[index] : (script.last ?? .idle)
      index += 1
      return PresenceReading(presence: presence, confidence: .reported)
    }
  }

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
    readings: ScriptedReadings, delivered: LockIsolated<[String]>, attachment: Attachment
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
    await store.addConnection(id: UUID(), fileDescriptor: attachment.daemonEnd)
    return (store, ids[0], ids[1])
  }

  private func plain(_ delivered: LockIsolated<[String]>) -> [String] {
    delivered.value.map { $0.replacingOccurrences(of: "[graphcode] Sender: ", with: "") }
  }

  /// PROBE A — a turn ending mid-drain reorders, with a SINGLE drain.
  ///
  /// The first read of the walk says busy, so item 1 is put back; the reads for items 2
  /// and 3 say idle, so they are delivered. Item 1 then arrives on the next drain. No
  /// two drains overlap, so #309's in-flight guard is not involved at all.
  @Test
  func aTurnEndingMidDrainReordersWithinOneDrain() async {
    // Read 1 stages the messages as busy; then the walk reads busy, idle, idle.
    let readings = ScriptedReadings([.busy, .busy, .idle, .idle, .idle])
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    await store.pollPresence()
    for index in 1...3 {
      await store.handle(
        .messageNode(target, text: "staged \(index)", from: sender, followUp: true))
    }
    #expect(delivered.value.isEmpty)

    await store.pollPresence()
    await store.pollPresence()

    let texts = plain(delivered)
    print("PROBE-A order: \(texts)")
    #expect(texts.count == 3)
    #expect(texts == ["staged 1", "staged 2", "staged 3"])
  }

  /// PROBE B — a later follow-up jumps the queue.
  ///
  /// `deliversLater` reads the CACHED `node.presence`; the drain reads LIVE per item.
  /// Cache says busy so message 1 stages; the live read in the drain also says busy so
  /// it stays queued; then message 2 arrives while the cache still says busy — it too
  /// stages, so far so good. The jump is the other disagreement: the cache goes idle
  /// (the poll wrote it) while the live read is still busy, so message 2 is typed
  /// straight in ahead of the still-queued message 1.
  @Test
  func aLaterFollowUpDoesNotJumpAnEarlierOne() async {
    // Poll 1: busy → cached busy. Message 1 staged.
    // Poll 2's own read: idle → cached idle, then the drain's per-item read: busy → 1 requeued.
    // Message 2 now sees cached idle and is delivered live, ahead of message 1.
    let readings = ScriptedReadings([.busy, .idle, .busy, .idle, .idle, .idle])
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    await store.pollPresence()
    await store.handle(.messageNode(target, text: "first", from: sender, followUp: true))
    #expect(delivered.value.isEmpty)

    await store.pollPresence()
    await store.handle(.messageNode(target, text: "second", from: sender, followUp: true))
    await store.pollPresence()

    let texts = plain(delivered)
    print("PROBE-B order: \(texts)")
    #expect(texts == ["first", "second"])
  }

  /// PROBE C — re-scoping a watch keeps the abandoned topic's staged wakes.
  ///
  /// `mail watch --on --topic other` overwrites the subscription but never touches the
  /// wakes already queued for the old scope, and the drain's guard only asks whether
  /// *some* watch stands, never whether it still matches the post's topic.
  @Test
  func reScopingAWatchDropsTheAbandonedTopicsWakes() async {
    let readings = ScriptedReadings([.busy, .idle, .idle, .idle])
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, target, sender) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    await store.pollPresence()
    await store.handle(.mailroomWatch(on: true, topic: "alpha", from: target))
    await store.handle(.mailroomPost(text: "an alpha post", topic: "alpha", from: sender))
    #expect(delivered.value.isEmpty)

    // The watcher re-scopes to a different topic before the wake could land.
    await store.handle(.mailroomWatch(on: true, topic: "beta", from: target))
    await store.pollPresence()

    let texts = plain(delivered)
    print("PROBE-C delivered: \(texts)")
    #expect(texts.isEmpty)
  }
}
