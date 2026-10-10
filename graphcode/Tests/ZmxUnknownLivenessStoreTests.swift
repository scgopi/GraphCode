import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// Every GraphStore decision that would launch, kill, resolve or type on "not alive" asks
/// the three-way liveness instead, and does none of them for `.unknown`.
@Suite
struct ZmxUnknownLivenessStoreTests {
  private func goalDraft() -> NodeDraft {
    NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))
  }

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func openingAResolvedLoopNeverResumesIntoAnUnknownSession() async {
    for (liveness, resumes) in [(SessionLiveness.absent, 1), (.unknown, 0), (.live, 0)] {
      let resumed = LockIsolated<[UUID]>([])
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
      #expect(resumed.value.count == resumes, "\(liveness)")
    }
  }

  @Test
  func aLivenessHookIsDerivedFromTheBoolWhenNoneIsGiven() async {
    let resumed = LockIsolated(0)
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
    #expect(resumed.value == 1)
  }

  @Test
  func aPaneClosingOnAnUnknownSessionDoesNotResolveTheLoop() async {
    for (liveness, expected) in [
      (SessionLiveness.live, LoopState.running), (.unknown, .running), (.absent, .failed),
    ] {
      let memos = LockIsolated<[String]>([])
      let store = GraphStore(
        onSessionLiveness: { _, _ in liveness },
        onAppendMemory: { _, entry in memos.withValue { $0.append(entry) } })
      await store.handle(.createNode(goalDraft()))
      let id = await store.graph.nodes[0].id
      await store.handle(.nodeCheckRejected(id))
      #expect(await store.graph.nodes[id: id]?.state == expected, "\(liveness)")
      if liveness == .unknown {
        #expect(memos.value.contains { $0.contains("could not tell whether") })
      }
    }
  }

  @Test
  func aRetypeIntoAnUnknownSessionResumesNothingAndLosesNoMessage() async {
    let delivered = LockIsolated<[String]>([])
    let resumed = LockIsolated(0)
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

    #expect(await eventually { delivered.value.count == 3 })
    #expect(delivered.value.last == "/loop 1h check the flake")
    #expect(resumed.value == 0)
  }

  @Test
  func aReopenedGoalIsQueuedNotResumedWhenTheSessionIsUnknown() async {
    let delivered = LockIsolated<[String]>([])
    let resumed = LockIsolated(0)
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

    #expect(await eventually { delivered.value.contains { $0.contains("Add examples") } })
    #expect(resumed.value == 0)
  }
}
