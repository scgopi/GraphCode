import Foundation
import XCTest

@testable import GraphcodeKit

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

/// Every GraphStore decision that would launch, kill, resolve or type on "not alive" asks the
/// three-way liveness instead, and does none of them for `.unknown`.
final class ZmxUnknownLivenessStoreTests: XCTestCase {
  private func goalDraft() -> NodeDraft {
    NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
  }

  func testOpeningAResolvedLoopNeverResumesIntoAnUnknownSession() async {
    for (liveness, resumes) in [(SessionLiveness.absent, 1), (.unknown, 0), (.live, 0)] {
      let resumed = Locked<[UUID]>([])
      let store = GraphStore(
        onSessionLiveness: { _, _ in liveness },
        onResumeSession: { node, _ in
          resumed.withValue { $0.append(node.id) }
          return true
        })
      await store.handle(.createNode(goalDraft()))
      let id = await store.graph.nodes[0].id
      await store.handle(.completeNode(id, result: nil, from: id))
      await store.handle(.resumeSession(id))
      XCTAssertEqual(resumed.value.count, resumes, "\(liveness)")
    }
  }

  func testALivenessHookIsDerivedFromTheBoolWhenNoneIsGiven() async {
    let resumed = Locked<Int>(0)
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { _, _ in
        resumed.withValue { $0 += 1 }
        return true
      })
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.resumeSession(id))
    XCTAssertEqual(resumed.value, 1)
  }

  func testAPaneClosingOnAnUnknownSessionDoesNotResolveTheLoop() async {
    for (liveness, state) in [
      (SessionLiveness.live, LoopState.running), (.unknown, .running), (.absent, .failed),
    ] {
      let memos = Locked<[String]>([])
      let store = GraphStore(
        onSessionLiveness: { _, _ in liveness },
        onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
      await store.handle(.createNode(goalDraft()))
      let id = await store.graph.nodes[0].id
      await store.handle(.nodeCheckRejected(id))
      let actual = await store.graph.nodes[id: id]?.state
      XCTAssertEqual(actual, state, "\(liveness)")
      if liveness == .unknown {
        XCTAssertTrue(memos.value.contains { $0.contains("could not tell whether") })
      }
    }
  }

  /// A session whose liveness the test flips, with presence that always reads idle: the
  /// case a three-way check must still hold, because idle says nothing about whether the
  /// session exists.
  private final class Session: @unchecked Sendable {
    let liveness = Locked<SessionLiveness>(.unknown)
    let delivered = Locked<[String]>([])
    let resumed = Locked<Int>(0)
    let memos = Locked<[String]>([])

    func store() -> GraphStore {
      GraphStore(
        onDeliverMessage: { [self] _, text, _ in
          delivered.withValue { $0.append(text) }
          return true
        },
        onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
        onSessionLiveness: { [self] _, _ in liveness.value },
        onResumeSession: { [self] _, _ in
          resumed.withValue { $0 += 1 }
          return true
        },
        onAppendMemory: { [self] _, entry in memos.withValue { $0.append(entry) } })
    }
  }

  func testARetypeIntoAnUnknownSessionIsHeldThenDeliveredOnceWhenItIsLive() async {
    let session = Session()
    let store = session.store()
    let goal = NodeDraft(
      title: "Flake", loopType: .goalBased, goal: GoalSpec(summary: "the flake is fixed"))
    await store.handle(.createNode(goal))
    await store.handle(
      .promoteNode(
        goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))
    let held = await eventually {
      await store.handle(.resumeSession(goal.id))
      return session.memos.value.contains { $0.hasPrefix("follow-up staged") }
    }
    XCTAssertTrue(held, "held and staged")

    XCTAssertEqual(session.delivered.value, [], "nothing is typed while unknown")
    XCTAssertEqual(session.resumed.value, 0)
    let staged = session.memos.value.filter { $0.hasPrefix("follow-up staged") }
    XCTAssertFalse(staged.isEmpty, "held work is visible in the loop's memory")
    XCTAssertEqual(Set(staged).count, staged.count, "each is staged once: \(staged)")

    session.liveness.withValue { $0 = .live }
    let arrived = await eventually {
      await store.handle(.resumeSession(goal.id))
      return session.delivered.value.contains("/loop 1h check the flake")
    }
    XCTAssertTrue(arrived, "delivered: \(session.delivered.value)")
    XCTAssertEqual(
      session.delivered.value.count, Set(session.delivered.value).count,
      "each exactly once: \(session.delivered.value)")
    XCTAssertEqual(session.resumed.value, 0)
  }

  func testAReopenedGoalIsHeldThenDeliveredOnceWhenItIsLiveAndNeverResumed() async {
    let session = Session()
    let store = session.store()
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Add examples")))
    let held = await eventually {
      await store.handle(.resumeSession(id))
      return session.memos.value.contains { $0.hasPrefix("follow-up staged") }
    }
    XCTAssertTrue(held, "held and staged")

    XCTAssertEqual(session.delivered.value, [], "nothing is typed while unknown")
    XCTAssertEqual(session.resumed.value, 0)

    session.liveness.withValue { $0 = .live }
    let arrived = await eventually {
      await store.handle(.resumeSession(id))
      return session.delivered.value.contains { $0.contains("Add examples") }
    }
    XCTAssertTrue(arrived, "delivered: \(session.delivered.value)")
    XCTAssertEqual(session.delivered.value.filter { $0.contains("Add examples") }.count, 1)
    XCTAssertEqual(session.resumed.value, 0)
  }

  func testAnUnknownSessionTellsItsUserOnceWhatIsBeingHeld() async {
    let session = Session()
    let store = session.store()
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.resumeSession(id))
    await store.handle(.resumeSession(id))
    let notes = session.memos.value.filter { $0.contains("will be retried") }
    XCTAssertEqual(notes.count, 1, "\(notes)")
    XCTAssertEqual(session.resumed.value, 0)
  }
}
