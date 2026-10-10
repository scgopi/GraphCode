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

  /// A session whose liveness the test flips, with presence that always reads idle: the
  /// case a three-way check must still hold, because idle says nothing about whether the
  /// session exists.
  private final class Session: @unchecked Sendable {
    let liveness = LockIsolated<SessionLiveness>(.unknown)
    let delivered = LockIsolated<[String]>([])
    let resumed = LockIsolated(0)
    let memos = LockIsolated<[String]>([])

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

  @Test
  func aRetypeIntoAnUnknownSessionIsHeldThenDeliveredOnceWhenItIsLive() async {
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
    #expect(held, "held and staged")

    #expect(session.delivered.value.isEmpty, "nothing is typed while unknown")
    #expect(session.resumed.value == 0)
    let staged = session.memos.value.filter { $0.hasPrefix("follow-up staged") }
    #expect(!staged.isEmpty, "held work is visible in the loop's memory")
    #expect(Set(staged).count == staged.count, "each is staged once: \(staged)")

    session.liveness.withValue { $0 = .live }
    let arrived = await eventually {
      await store.handle(.resumeSession(goal.id))
      return session.delivered.value.contains("/loop 1h check the flake")
    }
    #expect(arrived, "delivered: \(session.delivered.value)")
    #expect(
      session.delivered.value.count == Set(session.delivered.value).count,
      "each exactly once: \(session.delivered.value)")
    #expect(session.resumed.value == 0)
  }

  @Test
  func aReopenedGoalIsHeldThenDeliveredOnceWhenItIsLiveAndNeverResumed() async {
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
    #expect(held, "held and staged")

    #expect(session.delivered.value.isEmpty, "nothing is typed while unknown")
    #expect(session.resumed.value == 0)

    session.liveness.withValue { $0 = .live }
    let arrived = await eventually {
      await store.handle(.resumeSession(id))
      return session.delivered.value.contains { $0.contains("Add examples") }
    }
    #expect(arrived, "delivered: \(session.delivered.value)")
    #expect(session.delivered.value.filter { $0.contains("Add examples") }.count == 1)
    #expect(session.resumed.value == 0)
  }

  @Test
  func anUnknownSessionTellsItsUserOnceWhatIsBeingHeld() async {
    let session = Session()
    let store = session.store()
    await store.handle(.createNode(goalDraft()))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.resumeSession(id))
    await store.handle(.resumeSession(id))
    let notes = session.memos.value.filter { $0.contains("will be retried") }
    #expect(notes.count == 1, "\(notes)")
    #expect(session.resumed.value == 0)
  }
}
