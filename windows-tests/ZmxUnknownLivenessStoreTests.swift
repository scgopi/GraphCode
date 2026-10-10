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

  func testARetypeIntoAnUnknownSessionResumesNothingAndLosesNoMessage() async {
    let delivered = Locked<[String]>([])
    let resumed = Locked<Int>(0)
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onSessionLiveness: { _, _ in .unknown },
      onResumeSession: { _, _ in
        resumed.withValue { $0 += 1 }
        return true
      })
    let goal = NodeDraft(
      title: "Flake", loopType: .goalBased, goal: GoalSpec(summary: "the flake is fixed"))
    await store.handle(.createNode(goal))
    await store.handle(
      .promoteNode(
        goal.id, promotion: .timed(triggerPrompt: "/loop 1h check the flake"), promotedBy: nil))

    let arrived = await eventually { delivered.value.count == 3 }
    XCTAssertTrue(arrived, "delivered: \(delivered.value)")
    XCTAssertEqual(delivered.value.last, "/loop 1h check the flake")
    XCTAssertEqual(resumed.value, 0)
  }

  func testAReopenedGoalIsQueuedNotResumedWhenTheSessionIsUnknown() async {
    let delivered = Locked<[String]>([])
    let resumed = Locked<Int>(0)
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onSessionLiveness: { _, _ in .unknown },
      onResumeSession: { _, _ in
        resumed.withValue { $0 += 1 }
        return true
      })
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Add examples")))

    let arrived = await eventually { delivered.value.contains { $0.contains("Add examples") } }
    XCTAssertTrue(arrived, "delivered: \(delivered.value)")
    XCTAssertEqual(resumed.value, 0)
  }
}
