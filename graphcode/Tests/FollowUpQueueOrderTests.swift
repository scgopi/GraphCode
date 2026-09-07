import ComposableArchitecture
import Foundation
import GraphcodeKit
import MailroomKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// The seam #309 left behind: how a staged follow-up decides *when* to be delivered.
///
/// One test per defect, each failing on the head before this change for its own reason —
/// a combined test that passes says nothing about which half works:
///
/// - `aHungPresenceReadDoesNotStopDeliveryToOtherLoops` — #311, the unbounded read.
/// - `tenStagedAndSixLaterMessagesArriveInSendOrder` — #311, the two readings.
/// - `aTurnEndingMidDrainDoesNotReorderTheQueue` — #304 residual, ordering.
/// - `reScopingAWatchDropsTheAbandonedTopicsStagedWakes` — #304 residual, re-scoping.
/// - `aBacklogDrainsInOnePassRatherThanOnePerTick` — the rate the field measurement found.
@Suite
struct FollowUpQueueOrderTests {
  /// What each target's session appears to be doing. Every knob is set by the test
  /// before the pass it applies to, so nothing here depends on how many times the store
  /// happens to ask — which is the difference between the two heads this must separate.
  private actor Readings {
    private var fallback: Presence = .busy
    private var first: Presence?
    private var reads = 0
    private var delay: Duration = .zero
    private var hang: Duration = .zero
    private var hung: UUID?

    func set(_ presence: Presence, delay: Duration = .zero) {
      fallback = presence
      first = nil
      reads = 0
      self.delay = delay
    }

    /// The turn boundary: the pass's first reading says `first`, everything after it
    /// says `rest`. A drain that reads once per target per pass sees only `first`; one
    /// that reads per item sees the session change under it mid-batch.
    func firstReadThen(_ first: Presence, _ rest: Presence) {
      self.first = first
      fallback = rest
      reads = 0
    }

    func hang(_ node: UUID, for duration: Duration) {
      hung = node
      hang = duration
    }
    func stopHanging() { hung = nil }

    func read(_ node: UUID) async -> PresenceReading {
      if node == hung { try? await Task.sleep(for: hang) }
      if delay > .zero { try? await Task.sleep(for: delay) }
      reads += 1
      let presence = reads == 1 ? (first ?? fallback) : fallback
      return PresenceReading(presence: presence, confidence: .reported)
    }
  }

  /// A connection with a channel lifecycle of its own and a reader draining it, so the
  /// presence poll runs — the rig `FollowUpDrainTests` needs, for the same reason.
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
    readings: Readings, delivered: LockIsolated<[String]>, attachment: Attachment,
    titles: [String] = ["Target", "Sender"], deadline: Duration = .seconds(45)
  ) async -> (GraphStore, ids: [UUID]) {
    let store = GraphStore(
      onEnsureSession: { _, _ in },
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { node, _ in await readings.read(node.id) },
      onMailroomEnabled: { true },
      presenceReadDeadline: deadline)
    for title in titles {
      await store.handle(
        .createNode(NodeDraft(title: title, loopType: .turnBased, firstInstruction: "Work")))
    }
    await store.addConnection(id: UUID(), fileDescriptor: attachment.daemonEnd)
    // One poll so every target carries a `busy` reading: that is what stages a follow-up
    // rather than typing it in, on this head and on the one before it.
    await store.pollPresence()
    return (store, await store.graph.nodes.map(\.id))
  }

  /// Settles the store — every command ends in the drain — without refreshing presence
  /// on the way, so the drain's own readings are the only ones the test's script sees.
  /// `.refreshUsage` polls presence first, which is right for the poll and wrong here.
  private func settle(_ store: GraphStore, _ nodeID: UUID) async {
    await store.handle(.memoNode(nodeID, text: "settle", from: nodeID))
  }

  private func plain(_ delivered: [String]) -> [String] {
    delivered.map { $0.replacingOccurrences(of: "[graphcode] Sender: ", with: "") }
  }

  /// Issue #311, the presence read with no deadline — the blocker, because a wedged
  /// drain and an empty one report exactly the same thing from outside.
  ///
  /// `onReadPresence` reaches `PTYProcessSession.waitCollectingOutput`, which ends only
  /// when the probe's `terminationHandler` closes the stream; `ssh`'s `ConnectTimeout`
  /// bounds the connect, not a command hanging on a host that has gone away. One such
  /// read held `isDrainingFollowUps` for the life of the daemon, so mail for **every
  /// other loop in the project** stopped — which is what this measures: not that the
  /// wedged loop recovers, but that its neighbour is not taken down with it.
  ///
  /// Fails before the fix on elapsed time: the pass waits out the hung read.
  @Test
  func aHungPresenceReadDoesNotStopDeliveryToOtherLoops() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, ids) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment,
      titles: ["Wedged", "Neighbour", "Sender"], deadline: .milliseconds(200))
    let (wedged, neighbour, sender) = (ids[0], ids[1], ids[2])

    await store.handle(
      .messageNode(wedged, text: "for the wedged loop", from: sender, followUp: true))
    await store.handle(
      .messageNode(neighbour, text: "for the neighbour", from: sender, followUp: true))
    #expect(delivered.value.isEmpty)

    // The wedged loop's session stops answering; every other read is instant and idle.
    await readings.hang(wedged, for: .seconds(5))
    await readings.set(.idle)
    let started = Date()
    await store.handle(.refreshUsage)
    let elapsed = Date().timeIntervalSince(started)

    #expect(plain(delivered.value) == ["for the neighbour"])
    #expect(elapsed < 2)
    // Not delivered blindly either: a read that ran out of time is `.unknown`, which is
    // no state at all, so the message is still owed rather than spent.
    await readings.stopHanging()
    await store.handle(.refreshUsage)
    #expect(plain(delivered.value) == ["for the neighbour", "for the wedged loop"])
  }

  /// Issue #311, the two readings — and the shape `MailDeliveryCheck` measured against
  /// the live 0.1.64-beta5 daemon: ten messages sat staged and drained 77 to 147 seconds
  /// later while six sent afterwards arrived within half a second, because those six
  /// took the immediate path off a cached `idle` while the queue was still being worked
  /// through. Order was perfect within each path and meaningless across them.
  ///
  /// Reproduced the same way here: the poll writes `idle` into the cache, and the later
  /// messages arrive while that poll's own drain is still running.
  ///
  /// Fails before the fix on order — the six overtake the ten.
  @Test
  func tenStagedAndSixLaterMessagesArriveInSendOrder() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, ids) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    let (target, sender) = (ids[0], ids[1])
    for index in 1...10 {
      await store.handle(
        .messageNode(target, text: "staged \(index)", from: sender, followUp: true))
    }
    #expect(delivered.value.isEmpty)

    // Idle now, and slow to answer: the poll's refresh writes `idle` into the cache
    // inside the first 400ms, and its drain is still going at 600ms.
    await readings.set(.idle, delay: .milliseconds(200))
    async let poll: Void = store.pollPresence()
    try? await Task.sleep(for: .milliseconds(600))
    for index in 1...6 {
      await store.handle(
        .messageNode(target, text: "later \(index)", from: sender, followUp: true))
    }
    await poll
    await store.pollPresence()

    let expected =
      (1...10).map { "staged \($0)" } + (1...6).map { "later \($0)" }
    #expect(plain(delivered.value) == expected)
  }

  /// Issue #304's residual: a single drain reorders when the target's turn ends while
  /// the drain is running. The first item is read mid-turn and put back; the next two are
  /// read after the turn ends and go out — [2, 3, 1], with no overlapping drain anywhere,
  /// which is why #309's non-reentrancy guard cannot see it.
  ///
  /// The reading is now taken once per target per pass, so a batch either goes out in
  /// order or waits together for a pass that can deliver all of it.
  ///
  /// Fails before the fix on order: `["staged 2", "staged 3", "staged 1"]`.
  @Test
  func aTurnEndingMidDrainDoesNotReorderTheQueue() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, ids) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    let (target, sender) = (ids[0], ids[1])
    for index in 1...3 {
      await store.handle(
        .messageNode(target, text: "staged \(index)", from: sender, followUp: true))
    }
    #expect(delivered.value.isEmpty)

    // The turn ends between the first item and the second.
    await readings.firstReadThen(.busy, .idle)
    await settle(store, target)

    await readings.set(.idle)
    await settle(store, target)

    #expect(plain(delivered.value) == ["staged 1", "staged 2", "staged 3"])
  }

  /// Issue #304's other residual: `mail watch --on --topic other` re-scopes an existing
  /// watch, and the wakes staged under the topic it left kept arriving — the same defect
  /// `--off` had, reached by the command that does not read like a teardown.
  ///
  /// Fails before the fix by delivering the abandoned topic's wake as well.
  @Test
  func reScopingAWatchDropsTheAbandonedTopicsStagedWakes() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, ids) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    let (target, sender) = (ids[0], ids[1])

    await store.handle(.mailroomWatch(on: true, topic: "alpha", from: target))
    await store.handle(.mailroomPost(text: "an alpha finding", topic: "alpha", from: sender))
    // Re-scoped, without ever passing through `--off`.
    await store.handle(.mailroomWatch(on: true, topic: "beta", from: target))
    await store.handle(.mailroomPost(text: "a beta finding", topic: "beta", from: sender))
    #expect(delivered.value.isEmpty)

    await readings.set(.idle)
    await store.pollPresence()

    #expect(delivered.value.count == 1)
    #expect(delivered.value.first?.contains("a beta finding") == true)
    #expect(!delivered.value.contains { $0.contains("an alpha finding") })
  }

  /// The rate `MailDeliveryCheck` measured on the live daemon and nobody had filed:
  /// about **two deliveries per poll tick**, so ten staged messages took 147 seconds.
  /// Delivering into a session is what makes it busy, and a drain that re-read presence
  /// between items therefore stopped after the first delivery of every pass and waited
  /// for the next tick — the queue drained at one item per fifteen seconds.
  ///
  /// One reading per target per pass ends it: the pass judges the target once, before it
  /// has typed anything into it, and hands over the whole backlog in that pass.
  ///
  /// Fails before the fix on count: one delivered per pass, not ten.
  @Test
  func aBacklogDrainsInOnePassRatherThanOnePerTick() async {
    let readings = Readings()
    let delivered = LockIsolated<[String]>([])
    let attachment = Attachment()
    let (store, ids) = await makeStore(
      readings: readings, delivered: delivered, attachment: attachment)
    let (target, sender) = (ids[0], ids[1])
    for index in 1...10 {
      await store.handle(
        .messageNode(target, text: "backlog \(index)", from: sender, followUp: true))
    }
    #expect(delivered.value.isEmpty)

    // Idle when the pass begins, busy from the moment the first message is typed in.
    await readings.firstReadThen(.idle, .busy)
    await settle(store, target)

    #expect(plain(delivered.value) == (1...10).map { "backlog \($0)" })
  }
}
