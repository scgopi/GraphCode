import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Issue #311's wedge, from the rig `StableSoakCheck` reproduced it with on a real
/// `graphcoded` (`worktrees/stable-check-311`, `probe/311-drain-wedge`): a control run
/// delivered a bystander's queued mail in ~15s, and the run that differs in **one
/// closure** — node A's presence read hangs — never delivered it in 364 seconds, with a
/// client attached throughout and zero errors logged.
///
/// Its tests asserted the freeze, since that was what beta5 did. These are the same
/// scenarios with the assertions turned round to what this branch does instead, plus the
/// one its report asked for that no deadline can give: a hang in a path with no deadline
/// at all.
@Suite
struct DrainWedgeTests {
  private struct Fixture {
    let graph: LoopGraph
    var hung: UUID { graph.nodes[0].id }
    var bystander: UUID { graph.nodes[1].id }
  }

  private func fixture() -> Fixture {
    Fixture(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/drainwedge", name: "drainwedge"),
        nodes: [
          LoopNode(
            title: "Hung", loopType: .goalBased, goal: GoalSpec(summary: "hangs"),
            presence: PresenceReading(presence: .busy, confidence: .reported),
            state: .running),
          LoopNode(
            title: "Bystander", loopType: .goalBased, goal: GoalSpec(summary: "innocent"),
            presence: PresenceReading(presence: .busy, confidence: .reported),
            state: .running),
        ]))
  }

  private func settle(until flag: LockIsolated<Bool>) async {
    for _ in 0..<2000 where !flag.value { try? await Task.sleep(for: .milliseconds(5)) }
  }

  /// The control, unchanged from the probe: node A's read answers `busy`, so the drain
  /// steps past it and reaches node B, whose reading is idle.
  @Test
  func aBystandersFollowUpIsDeliveredWhenEveryPresenceReadAnswers() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: fixture.graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { node, _ in
        PresenceReading(
          presence: node.id == fixture.hung ? .busy : .idle, confidence: .reported)
      })

    await store.handle(
      .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))

    #expect(delivered.value == ["[graphcode] for the bystander"])
  }

  /// The wedge. Same graph, same two messages; node A's read never returns.
  ///
  /// On beta5 both the command that queued A's follow-up and every later drain were
  /// held for the life of the process, and B's mail was never typed in however idle B
  /// was. Bounded, the read is `.unknown` after the deadline, which is no state at all:
  /// A's message stays owed and B's is delivered in the same pass.
  @Test
  func aHungPresenceReadDoesNotFreezeEveryOtherLoopsFollowUps() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let announced = LockIsolated<[String]>([])
    let entered = LockIsolated(false)
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { node, _ in
        guard node.id == fixture.hung else {
          return PresenceReading(presence: .idle, confidence: .reported)
        }
        entered.setValue(true)
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        return PresenceReading(presence: .busy, confidence: .reported)
      },
      onAnnounceError: { message in announced.withValue { $0.append(message) } },
      presenceReadDeadline: .milliseconds(200))

    // Queued in a task of its own so this test *fails* on the head where the drain never
    // returns, rather than hanging with it.
    let wedging = Task {
      await store.handle(
        .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    }
    await settle(until: entered)
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))
    // Past the deadline the wedged pass is over, and the next settle carries B's mail.
    try? await Task.sleep(for: .milliseconds(400))
    await store.handle(.memoNode(fixture.bystander, text: "settle", from: fixture.bystander))

    #expect(delivered.value == ["[graphcode] for the bystander"])
    #expect(announced.value.isEmpty)
    release.setValue(true)
    _ = await wedging.value
  }

  /// The same hang one layer up: `refreshPresence` walks the graph serially, so on beta5
  /// the poll tick never reached the nodes behind the hung one and their presence stopped
  /// being read at all. The bound is on the reading itself, so the walk continues.
  @Test
  func aHungPresenceReadDoesNotStopThePollTickReachingLaterLoops() async {
    let fixture = fixture()
    let asked = LockIsolated<[UUID]>([])
    let entered = LockIsolated(false)
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      onReadPresence: { node, _ in
        asked.withValue { $0.append(node.id) }
        guard node.id == fixture.hung else {
          return PresenceReading(presence: .idle, confidence: .reported)
        }
        entered.setValue(true)
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        return PresenceReading(presence: .busy, confidence: .reported)
      },
      presenceReadDeadline: .milliseconds(200))

    let wedging = Task { await store.handle(.refreshUsage) }
    await settle(until: entered)
    try? await Task.sleep(for: .milliseconds(400))

    #expect(asked.value.contains(fixture.hung))
    #expect(asked.value.contains(fixture.bystander))
    release.setValue(true)
    _ = await wedging.value
  }

  /// What the deadline cannot reach, and the reason the guard is a lease.
  ///
  /// `deliverToSession` is the same `PTYProcessSession` chain as the presence read and
  /// has no deadline of its own — `zmx ls`, a write per chunk, `ssh` for a remote loop.
  /// A hang there holds a bare flag exactly as the presence read did, and the failure is
  /// the one the soak measured: total, and silent. So the guard expires: the next drain
  /// records the stall in the daemon log and takes the queue on.
  @Test
  func aHungDeliveryReleasesTheQueueWhenItsLeaseExpires() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let typed = LockIsolated<[String]>([])
    let lines = LockIsolated<[String]>([])
    let entered = LockIsolated(false)
    let release = LockIsolated(false)
    let tap = DaemonLog.shared.tap { line in lines.withValue { $0.append(line) } }
    defer { DaemonLog.shared.untap(tap) }
    let store = GraphStore(
      graph: fixture.graph,
      onDeliverMessage: { node, message, _ in
        typed.withValue { $0.append(message) }
        guard node.id == fixture.hung else {
          delivered.withValue { $0.append(message) }
          return true
        }
        entered.setValue(true)
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      presenceReadDeadline: .milliseconds(200),
      drainLeaseDuration: .milliseconds(300))

    // The drain that hands A its message never returns from the delivery.
    let wedging = Task {
      await store.handle(
        .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    }
    await settle(until: entered)

    // While the lease stands, the queue is the wedged drain's: B waits.
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))
    #expect(delivered.value.isEmpty)

    // Past the lease, the next drain takes over and says so.
    try? await Task.sleep(for: .milliseconds(350))
    await store.handle(.memoNode(fixture.bystander, text: "settle", from: fixture.bystander))

    #expect(delivered.value == ["[graphcode] for the bystander"])
    #expect(typed.value == ["[graphcode] for the hung one", "[graphcode] for the bystander"])
    #expect(lines.value.contains { $0.contains("event=drain-stall") })
    release.setValue(true)
    _ = await wedging.value
    #expect(typed.value == ["[graphcode] for the hung one", "[graphcode] for the bystander"])
  }
}
