import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The two halves a bare exit status threw away: a failing stop condition telling the
/// session *why* it isn't done (`relayPredicateFailure`), and an expensive predicate
/// declining to re-run against a tree that hasn't changed since it last failed
/// (`GoalSpec.skipsUnchangedWorkspace`).
@Suite
struct PredicateFeedbackTests {
  private func goalGraph(
    presence: Presence? = .idle, skipsUnchanged: Bool = false
  ) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/feedback", name: "feedback"),
      nodes: [
        LoopNode(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(
            summary: "CI passes", predicate: "make test",
            skipsUnchangedWorkspace: skipsUnchanged),
          presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
          state: .running)
      ])
  }

  @Test
  func aFailingPredicateTellsAnIdleSessionWhatItPrinted() async {
    let delivered = LockIsolated<[String]>([])
    let remembered = LockIsolated<[String]>([])
    let graph = goalGraph()
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in PredicateOutcome(passed: false, outputTail: "2 tests failed") },
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })

    await store.evaluateGoal(graph.nodes[0].id)

    #expect(await store.graph.nodes[0].state == .running)
    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].contains("make test"))
    #expect(delivered.value[0].contains("2 tests failed"))
    #expect(remembered.value.contains { $0.contains("predicate feedback: 2 tests failed") })
  }

  @Test
  func theSameFailureIsRelayedOnceNotEveryPoll() async {
    let delivered = LockIsolated(0)
    let graph = goalGraph()
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in PredicateOutcome(passed: false, outputTail: "2 tests failed") },
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(delivered.value == 1)
  }

  @Test
  func aBusySessionIsNotInterruptedWithFeedback() async {
    // A busy agent is still working; it will be judged again next poll. The relay
    // exists for the session that believes it is finished.
    let delivered = LockIsolated(0)
    let graph = goalGraph(presence: .busy)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in PredicateOutcome(passed: false, outputTail: "still failing") },
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      })

    await store.evaluateGoal(graph.nodes[0].id)

    #expect(delivered.value == 0)
  }

  @Test
  func aPassingCheckedPredicateStillResolvesTheNode() async {
    let graph = goalGraph()
    let store = GraphStore(
      graph: graph, onCheckPredicate: { _ in PredicateOutcome(passed: true) })

    await store.evaluateGoal(graph.nodes[0].id)

    #expect(await store.graph.nodes[0].state == .succeeded)
  }

  @Test
  func anUnchangedTreeSkipsTheRerunUntilItChanges() async {
    let fingerprint = LockIsolated("tree-1")
    let evaluated = LockIsolated(0)
    let graph = goalGraph(presence: .busy, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onCaptureScript: { _ in fingerprint.value })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)
    #expect(evaluated.value == 1)

    fingerprint.setValue("tree-2")
    await store.evaluateGoal(graph.nodes[0].id)
    #expect(evaluated.value == 2)
  }

  @Test
  func aMissingFingerprintMeansThePredicateAlwaysRuns() async {
    // Outside a git repository "the tree changed" has no meaning, so the skip — an
    // optimisation, never the rule — simply doesn't apply.
    let evaluated = LockIsolated(0)
    let graph = goalGraph(presence: .busy, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onCaptureScript: { _ in nil })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(evaluated.value == 2)
  }

  @Test
  func withoutOptingInThePredicateRunsEveryPoll() async {
    // The default stays off with reason: predicates that watch things outside the
    // tree — CI, a deploy — would otherwise wait on a change that never comes.
    let evaluated = LockIsolated(0)
    let graph = goalGraph(presence: .busy)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onCaptureScript: { _ in "tree-1" })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(evaluated.value == 2)
  }

  @Test
  func anIdleLoopOnAnUnchangedTreeIsWokenOnceNotEveryPoll() async {
    // The stranding from issue #217 item 13: a goal loop is the only writer of its
    // tree, and it only writes once woken — so gating the wake on a tree change waits
    // on the loop that is asleep. Idle plus unchanged is wake-worthy, but bounded:
    // one re-delivery per frozen tree, because every further one is a full agent turn
    // — the spend the failure-tail dedup exists to prevent.
    let evaluated = LockIsolated(0)
    let delivered = LockIsolated(0)
    let graph = goalGraph(presence: .idle, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onCaptureScript: { _ in "tree-1" })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(evaluated.value == 2)
    #expect(delivered.value == 2)
  }

  @Test
  func aTreeChangeBuysOneMoreWakeOnTheNextFreeze() async {
    // The bound is per frozen tree, not per loop: each failing run at a new
    // fingerprint leaves the idle loop one more notice it may be given if the tree
    // freezes again — that is what keeps "skip until changed" from becoming "skip
    // until stopped".
    let fingerprint = LockIsolated("tree-1")
    let evaluated = LockIsolated(0)
    let delivered = LockIsolated(0)
    let graph = goalGraph(presence: .idle, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onDeliverMessage: { _, _, _ in
        delivered.withValue { $0 += 1 }
        return true
      },
      onCaptureScript: { _ in fingerprint.value })

    await store.evaluateGoal(graph.nodes[0].id)  // first failing run: told
    await store.evaluateGoal(graph.nodes[0].id)  // idle on tree-1: its one wake
    await store.evaluateGoal(graph.nodes[0].id)  // skip holds
    fingerprint.setValue("tree-2")
    await store.evaluateGoal(graph.nodes[0].id)  // tree moved: re-run; same tail, not told
    await store.evaluateGoal(graph.nodes[0].id)  // idle on tree-2: one more wake
    await store.evaluateGoal(graph.nodes[0].id)  // skip holds again

    #expect(evaluated.value == 4)
    #expect(delivered.value == 3)
  }

  @Test
  func aPresencelessSessionStaysSkippedRatherThanPayingForAWakeThatCannotLand() async {
    // The relay only ever tells a session it can see idle; with no presence reading
    // no wake can land, so the skip holds instead of spending predicate runs on one.
    // Such a loop's exits are its stall bound and its human.
    let evaluated = LockIsolated(0)
    let graph = goalGraph(presence: nil, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: false, outputTail: "no")
      },
      onCaptureScript: { _ in "tree-1" })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(evaluated.value == 1)
  }

  @Test
  func anIdleLoopOnAnUnchangedTreeStillNoticesThePredicatePassing() async {
    // The other half of the same deadlock: with the tree frozen, the only way a
    // CI-watching predicate ever goes green is on a poll the skip used to eat.
    let evaluated = LockIsolated(0)
    let graph = goalGraph(presence: .idle, skipsUnchanged: true)
    let store = GraphStore(
      graph: graph,
      onCheckPredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return PredicateOutcome(passed: evaluated.value > 1, outputTail: "no")
      },
      onDeliverMessage: { _, _, _ in true },
      onCaptureScript: { _ in "tree-1" })

    await store.evaluateGoal(graph.nodes[0].id)
    await store.evaluateGoal(graph.nodes[0].id)

    #expect(await store.graph.nodes[0].state == .succeeded)
  }

  @Test
  func theCLIParsesSkipUnchanged() throws {
    let create = try GraphcodeCommand.parse([
      "node", "create", "/tmp/p", "--title", "S", "--type", "goal",
      "--goal", "done", "--predicate", "make test", "--skip-unchanged",
    ])
    guard case .createNode(_, let draft, _) = create else {
      Issue.record("expected createNode, got \(create)")
      return
    }
    #expect(draft.goal?.skipsUnchangedWorkspace == true)

    let update = try GraphcodeCommand.parse([
      "node", "update", "/tmp/p", UUID().uuidString, "--skip-unchanged", "false",
    ])
    guard case .updateNode(_, _, let nodeUpdate) = update else {
      Issue.record("expected updateNode, got \(update)")
      return
    }
    #expect(nodeUpdate.skipsUnchangedWorkspace == false)
  }

  @Test
  func theCreateWarningFiresOnlyForSkipUnchangedPairedWithAPredicate() throws {
    let warned = try GraphcodeCommand.parse([
      "node", "create", "/tmp/p", "--title", "S", "--type", "goal",
      "--goal", "done", "--predicate", "make test", "--skip-unchanged",
    ])
    guard case .createNode(_, let warnedDraft, _) = warned else {
      Issue.record("expected createNode, got \(warned)")
      return
    }
    let warnings = GraphcodeCommand.createWarnings(for: warnedDraft)
    #expect(warnings.count == 1)
    #expect(warnings[0].contains("idle"))

    let unwarned = try GraphcodeCommand.parse([
      "node", "create", "/tmp/p", "--title", "S", "--type", "goal",
      "--goal", "done", "--predicate", "make test",
    ])
    guard case .createNode(_, let unwarnedDraft, _) = unwarned else {
      Issue.record("expected createNode, got \(unwarned)")
      return
    }
    #expect(GraphcodeCommand.createWarnings(for: unwarnedDraft).isEmpty)
  }

  @Test
  func theUpdateWarningFiresWhenSkipUnchangedIsTurnedOnForAPredicatedGoalLoop() throws {
    let graph = goalGraph()
    let parsed = try GraphcodeCommand.parse([
      "node", "update", "/tmp/p", UUID().uuidString, "--skip-unchanged", "true",
    ])
    guard case .updateNode(_, _, let nodeUpdate) = parsed else {
      Issue.record("expected updateNode, got \(parsed)")
      return
    }
    #expect(
      GraphcodeCommand.updateWarnings(for: nodeUpdate, currentNode: graph.nodes[0]).count == 1)
    // Best-effort: a node the client cannot see (a sub-graph child) warns nobody.
    #expect(GraphcodeCommand.updateWarnings(for: nodeUpdate, currentNode: nil).isEmpty)
  }
}
