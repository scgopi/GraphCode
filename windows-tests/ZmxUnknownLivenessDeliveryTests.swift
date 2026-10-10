import Foundation
import XCTest

@testable import GraphcodeKit

/// A delivery that hits an unknown session is deferred, not read as a dead one: the callers
/// that kill or relaunch on a failed delivery must not, and queued work keeps its recovery
/// policy (resume if the session is later found definitely absent).
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
  func withValue(_ body: (inout Value) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&stored)
  }
}

final class ZmxUnknownLivenessDeliveryTests: XCTestCase {
  private func goalDraft() -> NodeDraft {
    NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))
  }

  /// Answers from a script, one entry per call; the last repeats.
  private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [SessionLiveness]
    init(_ steps: [SessionLiveness]) { self.steps = steps }
    func next() -> SessionLiveness {
      lock.lock()
      defer { lock.unlock() }
      return steps.count > 1 ? steps.removeFirst() : (steps.first ?? .unknown)
    }
  }

  func testAStopNeverKillsASessionZmxCouldNotClassify() async {
    let cases: [(String, [SessionLiveness], Int)] = [
      ("unknown", [.unknown], 0),
      ("live, then unknown when the refused send is re-read", [.live, .unknown], 0),
      ("absent", [.absent], 1),
    ]
    for (name, steps, kills) in cases {
      let script = Script(steps)
      let killed = Locked(0)
      let memos = Locked<[String]>([])
      let store = GraphStore(
        onTerminateSession: { _, _ in killed.withValue { $0 += 1 } },
        onDeliverMessage: { _, _, _ in false },
        onSessionLiveness: { _, _ in script.next() },
        onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
      await store.handle(.createNode(goalDraft()))
      let id = await store.graph.nodes[0].id
      await store.handle(.stopNode(id))
      XCTAssertEqual(killed.value, kills, name)
      if kills == 0 {
        XCTAssertTrue(memos.value.contains { $0.contains("not killed") }, "\(memos.value)")
      }
    }
  }

  func testAnAdHocSendToAnUnknownSessionStagesAndNeverRelaunches() async {
    let ensured = Locked(0)
    let memos = Locked<[String]>([])
    let store = GraphStore(
      onEnsureSession: { _, _ in ensured.withValue { $0 += 1 } },
      onDeliverMessage: { _, _, _ in false },
      onSessionAlive: { _, _ in true },
      onSessionLiveness: { _, _ in .unknown },
      onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    let before = ensured.value
    await store.handle(.messageNode(id, text: "ping", from: nil, followUp: false))
    await store.finishSessionTyping()
    XCTAssertEqual(ensured.value, before, "no second agent is launched beside an unknown one")
    XCTAssertTrue(memos.value.contains { $0.contains("ping") }, "\(memos.value)")
  }

  private final class Session: @unchecked Sendable {
    let liveness = Locked<SessionLiveness>(.unknown)
    let events = Locked<[String]>([])
    let memos = Locked<[String]>([])
    static let runningGoal = LoopGraph(
      project: ProjectRef(path: "/tmp/retype", name: "retype"),
      nodes: [
        LoopNode(
          title: "Flake", loopType: .goalBased, goal: GoalSpec(summary: "the flake is fixed"),
          state: .running)
      ])
    /// While set, the transport refuses every send, and the session then reads absent: the
    /// shape of a session that died between the liveness answer and the send.
    let refusing = Locked(false)
    private let refused = Locked(false)

    func store(running: Bool = false) -> GraphStore {
      GraphStore(
        graph: running
          ? Self.runningGoal : LoopGraph(project: ProjectRef(path: "", name: "Untitled")),
        onDeliverMessage: { [self] _, text, _ in
          if refusing.value {
            refused.withValue { $0 = true }
            return false
          }
          events.withValue { $0.append("deliver:" + text) }
          return true
        },
        onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
        onSessionLiveness: { [self] _, _ in refused.value ? .absent : liveness.value },
        onResumeSession: { [self] _, _ in
          events.withValue { $0.append("resume") }
          refusing.withValue { $0 = false }
          refused.withValue { $0 = false }
          return true
        },
        onAppendMemory: { [self] _, entry in memos.withValue { $0.append(entry) } })
    }
  }
  /// Re-runs `step` (a command that ends in a drain) until `condition` holds; the retype is
  /// delivered from a task of its own, so nothing is observable synchronously.
  private func eventually(
    step: (() async -> Void)? = nil, _ condition: () -> Bool
  ) async -> Bool {
    for _ in 0..<300 {
      if condition() { return true }
      await step?()
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }

  private func retype(_ store: GraphStore) async -> UUID {
    let goal = NodeDraft(
      title: "Flake", loopType: .goalBased, goal: GoalSpec(summary: "the flake is fixed"))
    await store.handle(.createNode(goal))
    await store.handle(
      .promoteNode(
        goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))
    return goal.id
  }

  func testAQueuedRetypeThatTurnsAbsentIsResumedOnceThenDeliveredOnceInOrder() async {
    let session = Session()
    let store = session.store()
    let id = await retype(store)
    let nudge: () async -> Void = { _ = await store.handle(.resumeSession(id)) }
    let held = await eventually(step: nudge) {
      session.memos.value.contains { $0.hasPrefix("follow-up staged") }
    }
    XCTAssertTrue(held, "held and staged while unknown")
    XCTAssertEqual(session.events.value, [])

    session.liveness.withValue { $0 = .absent }
    let resumed = await eventually(step: nudge) { session.events.value == ["resume"] }
    XCTAssertTrue(resumed, "\(session.events.value)")
    await nudge()
    await nudge()
    XCTAssertEqual(session.events.value, ["resume"], "resumed once, messages kept for it")

    session.liveness.withValue { $0 = .live }
    let done = await eventually(step: nudge) {
      session.events.value.last == "deliver:/loop 1h check the flake"
    }
    let events = session.events.value
    XCTAssertTrue(done, "\(events)")
    XCTAssertEqual(events.first, "resume")
    XCTAssertTrue(events.dropFirst().allSatisfy { $0.hasPrefix("deliver:") }, "\(events)")
    XCTAssertEqual(Set(events).count, events.count, "each exactly once: \(events)")
  }

  func testAQueuedRetypeThatTurnsLiveIsDeliveredOnceAndNeverResumed() async {
    let session = Session()
    let store = session.store()
    let id = await retype(store)
    let nudge: () async -> Void = { _ = await store.handle(.resumeSession(id)) }
    let held = await eventually(step: nudge) {
      session.memos.value.contains { $0.hasPrefix("follow-up staged") }
    }
    XCTAssertTrue(held)
    session.liveness.withValue { $0 = .live }
    let done = await eventually(step: nudge) {
      session.events.value.last == "deliver:/loop 1h check the flake"
    }
    await nudge()
    let events = session.events.value
    XCTAssertTrue(done, "\(events)")
    XCTAssertFalse(events.contains("resume"), "\(events)")
    XCTAssertEqual(Set(events).count, events.count, "each exactly once: \(events)")
  }

  func testALiveRetypeWhoseFinalSendIsRefusedAndSeesAbsentIsResumedNotDropped() async {
    let session = Session()
    session.liveness.withValue { $0 = .live }
    session.refusing.withValue { $0 = true }
    let store = session.store(running: true)
    let id = Session.runningGoal.nodes[0].id
    await store.handle(
      .promoteNode(
        id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))
    let nudge: () async -> Void = { _ = await store.handle(.resumeSession(id)) }
    let done = await eventually(step: nudge) {
      session.events.value.last == "deliver:/loop 1h check the flake"
    }
    let events = session.events.value
    XCTAssertTrue(done, "\(events)")
    XCTAssertEqual(events.first, "resume", "\(events)")
    XCTAssertTrue(events.dropFirst().allSatisfy { $0.hasPrefix("deliver:") }, "\(events)")
    XCTAssertEqual(Set(events).count, events.count, "each exactly once: \(events)")
  }
  func testAHungLivenessReadDoesNotBlockAnotherNodesQueuedFollowUps() async {
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/livenesswedge", name: "livenesswedge"),
      nodes: [
        LoopNode(
          title: "Hung", loopType: .goalBased, goal: GoalSpec(summary: "hangs"),
          presence: PresenceReading(presence: .busy, confidence: .reported), state: .running),
        LoopNode(
          title: "Bystander", loopType: .goalBased, goal: GoalSpec(summary: "innocent"),
          presence: PresenceReading(presence: .busy, confidence: .reported), state: .running),
      ])
    let hung = graph.nodes[0].id
    let bystander = graph.nodes[1].id
    let delivered = Locked<[String]>([])
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onSessionLiveness: { node, _ in
        if node.id == hung { try? await Task.sleep(for: .seconds(3600)) }
        return .live
      },
      livenessDeadline: .milliseconds(200))
    await store.handle(.messageNode(hung, text: "for the hung one", from: nil, followUp: true))
    await store.handle(
      .messageNode(bystander, text: "for the bystander", from: nil, followUp: true))
    await store.handle(.memoNode(bystander, text: "settle", from: bystander))
    XCTAssertEqual(delivered.value, ["[graphcode] for the bystander"], "\(delivered.value)")
  }
}
