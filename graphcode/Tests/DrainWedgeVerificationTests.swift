import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The stable-release check's wedge tests, inverted against #316.
///
/// On `main` at 0.1.64-beta5 each of these described a freeze; here they describe the
/// fix. The setup is byte-for-byte what was measured on beta5 — one loop whose presence
/// read never returns, one innocent bystander — so a regression restores the original
/// failure rather than a new one.
@Suite
struct DrainWedgeVerificationTests {
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

  /// Beta5: never delivered, for as long as a client stayed attached.
  /// Here: delivered, once the bounded read times out.
  @Test
  func aHungPresenceReadNoLongerFreezesTheBystandersFollowUp() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
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
        while !release.value { try? await Task.sleep(for: .milliseconds(20)) }
        return PresenceReading(presence: .busy, confidence: .reported)
      },
      presenceReadDeadline: .milliseconds(50))

    await store.handle(
      .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))

    #expect(delivered.value == ["[graphcode] for the bystander"])
    release.setValue(true)
  }

  /// The hung loop's own message is owed, not dropped: a timed-out read is `.unknown`,
  /// which is not a state, so the item stays queued for a pass that gets an answer.
  @Test
  func theHungLoopsOwnMessageIsStillOwedAndLandsWhenItAnswers() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { node, _ in
        guard node.id == fixture.hung else {
          return PresenceReading(presence: .busy, confidence: .reported)
        }
        while !release.value { try? await Task.sleep(for: .milliseconds(20)) }
        return PresenceReading(presence: .idle, confidence: .reported)
      },
      presenceReadDeadline: .milliseconds(50))

    await store.handle(
      .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    #expect(delivered.value.isEmpty)

    release.setValue(true)
    await store.handle(.refreshUsage)

    #expect(delivered.value == ["[graphcode] for the hung one"])
  }

  /// Point 3 of the stable check: on beta5 `refreshPresence` walked the graph serially
  /// through the same unbounded await, so nothing behind the hung node was ever read.
  @Test
  func thePollTickReachesLoopsBehindAHungOne() async {
    let fixture = fixture()
    let asked = LockIsolated<[UUID]>([])
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      onReadPresence: { node, _ in
        asked.withValue { $0.append(node.id) }
        guard node.id == fixture.hung else {
          return PresenceReading(presence: .idle, confidence: .reported)
        }
        while !release.value { try? await Task.sleep(for: .milliseconds(20)) }
        return PresenceReading(presence: .busy, confidence: .reported)
      },
      presenceReadDeadline: .milliseconds(50))

    await store.handle(.refreshUsage)

    #expect(asked.value.contains(fixture.bystander))
    release.setValue(true)
  }
}

/// The presence read is bounded now. The **delivery** in the same loop is not.
///
/// `deliverToSession` → `onDeliverMessage` → `CLISessionBackend.deliverMessage` →
/// `ZmxSessionLauncher.send` → `PTYProcessSession.waitCollectingOutput` is the same
/// unbounded chain the presence read had, and `GraphcodeKit/Sources/Sessions/` is
/// untouched by #316. So `drainPendingFollowUps` still holds `isDrainingFollowUps`
/// across an `await` that can never return — which is the premise the "no lease needed"
/// argument rests on.
///
/// A send is if anything the likelier of the two to wedge: a message is chunked into
/// several sequential `zmx send` invocations, so one message is several chances to hang
/// on a wedged `ControlMaster` rather than one.
@Suite
struct DeliveryWedgeTests {
  private struct Fixture {
    let graph: LoopGraph
    var hung: UUID { graph.nodes[0].id }
    var bystander: UUID { graph.nodes[1].id }
  }

  private func fixture() -> Fixture {
    Fixture(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/deliverywedge", name: "deliverywedge"),
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

  /// Waits for a delivery to arrive rather than sleeping a fixed span and hoping. The
  /// deadline these tests drive is 50ms, but the drain that acts on it competes with the
  /// rest of the suite — a flat sleep passes alone and fails under load, which reads as
  /// the timeout not working when it is only late.
  private func settle(until values: LockIsolated<[String]>, reaches count: Int) async {
    for _ in 0..<2000 where values.value.count < count {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  /// The control: every send returns, so the bystander is served.
  @Test
  func aBystandersFollowUpIsDeliveredWhenEverySendReturns() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: fixture.graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) })

    await store.handle(
      .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))

    #expect(delivered.value.contains("[graphcode] for the bystander"))
  }

  /// The same wedge as beta5, reached through the send instead of the read: one loop's
  /// `zmx send` never returns and every other loop's staged mail stops moving, silently,
  /// for as long as the process lives.
  ///
  /// The hung send eventually *succeeds*: the text was typed, late, so the store must
  /// count that delivery and never send the message a second time. The closure records
  /// the late success itself — a hung transport that returns is still the transport.
  @Test
  func aHungDeliveryStillFreezesEveryOtherLoopsFollowUps() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let entered = LockIsolated(false)
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      // Ahead of the closures because that is where `GraphStore.init` declares it, and
      // Swift matches an argument list in declaration order.
      deliveryDeadline: .milliseconds(50),
      onDeliverMessage: { node, message, _ in
        guard node.id == fixture.hung else {
          delivered.withValue { $0.append(message) }
          return true
        }
        entered.setValue(true)
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        delivered.withValue { $0.append(message) }
        return true
      },
      // Both loops read idle, so the drain tries to deliver to both.
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) })

    // Queued while both are mid-turn (cached `busy`), then delivered by the drain.
    let wedging = Task {
      await store.handle(
        .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    }
    await settle(until: entered)
    #expect(entered.value)

    // The store keeps answering: the wedged command returns when its send's deadline
    // passes, closure still hung, and the pass after it serves the bystander — whose
    // message was queued during that drain and so waits for the next one.
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))
    _ = await wedging.value
    await store.handle(.refreshUsage)

    #expect(delivered.value == ["[graphcode] for the bystander"])

    release.setValue(true)
    await settle(until: delivered, reaches: 2)
    #expect(delivered.value == ["[graphcode] for the bystander", "[graphcode] for the hung one"])

    // Exactly once: the late success took the item off the queue, so a pass finds nothing.
    await store.handle(.refreshUsage)
    await store.handle(.refreshUsage)
    #expect(delivered.value == ["[graphcode] for the bystander", "[graphcode] for the hung one"])
  }

  /// The other way a hung send can end: it *fails*. `zmx send` finally exits non-zero
  /// after the deadline passed. On #320's main that verdict staged the message to memory
  /// and dropped it from the live queue — the target is idle and answering, and the text
  /// it was owed never reaches its session. A failure is a failure whenever it is
  /// learned: staged once, retried at the next pass, delivered once.
  @Test
  func aTimedOutSendThatThenFailsIsRetriedExactlyOnce() async {
    let fixture = fixture()
    let delivered = LockIsolated<[String]>([])
    let remembered = LockIsolated<[String]>([])
    let attempts = LockIsolated(0)
    let entered = LockIsolated(false)
    let release = LockIsolated(false)
    let store = GraphStore(
      graph: fixture.graph,
      deliveryDeadline: .milliseconds(50),
      onDeliverMessage: { node, message, _ in
        guard node.id == fixture.hung else {
          delivered.withValue { $0.append(message) }
          return true
        }
        let attempt = attempts.withValue { value -> Int in
          value += 1
          return value
        }
        guard attempt == 1 else {
          delivered.withValue { $0.append(message) }
          return true
        }
        entered.setValue(true)
        while !release.value { try? await Task.sleep(for: .milliseconds(5)) }
        return false
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })

    let wedging = Task {
      await store.handle(
        .messageNode(fixture.hung, text: "for the hung one", from: nil, followUp: true))
    }
    await settle(until: entered)
    await store.handle(
      .messageNode(fixture.bystander, text: "for the bystander", from: nil, followUp: true))
    _ = await wedging.value
    await store.handle(.refreshUsage)
    #expect(delivered.value == ["[graphcode] for the bystander"])

    release.setValue(true)
    // No command drives this: the store retries on its own once the verdict lands.
    await settle(until: delivered, reaches: 2)
    #expect(delivered.value == ["[graphcode] for the bystander", "[graphcode] for the hung one"])
    #expect(remembered.value.filter { $0.contains("follow-up staged") }.count == 1)

    await store.handle(.refreshUsage)
    await store.handle(.refreshUsage)
    #expect(delivered.value == ["[graphcode] for the bystander", "[graphcode] for the hung one"])
    #expect(attempts.value == 2)
  }
}
