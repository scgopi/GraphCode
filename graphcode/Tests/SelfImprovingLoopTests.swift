import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// The self-improvement machinery: cycle re-entry nudges, hand-off payload delivery,
/// per-pass metric capture with the plateau bound, live-loop updates, and memory
/// episode records. Every test drives `GraphStore.handle`/`evaluateGoal` directly and
/// captures side effects through the injected closures — no filesystem, no sessions.
@Suite
struct SelfImprovingLoopTests {
  private struct Fixture {
    let store: GraphStore
    let delivered: LockIsolated<[(title: String, text: String)]>
    let memory: LockIsolated<[(nodeID: UUID, entry: String)]>
  }

  /// A maker → critic pair with a guarded back-edge closing the cycle, resolved by
  /// approving/rejecting checks so the tests control every pass boundary.
  private func makerCriticFixture(
    guardSpec: CycleGuard,
    deliverySucceeds: Bool = true,
    scriptOutput: String? = nil
  ) async -> (Fixture, maker: UUID, critic: UUID) {
    let delivered = LockIsolated<[(title: String, text: String)]>([])
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onEvaluatePredicate: { _ in false },
      onDeliverMessage: { node, text, _ in
        delivered.withValue { $0.append((node.title, text)) }
        return deliverySucceeds
      },
      onCaptureScript: { _ in scriptOutput },
      onAppendMemory: { nodeID, entry in
        memory.withValue { $0.append((nodeID, entry)) }
      })

    await store.handle(
      .createNode(
        NodeDraft(
          title: "Maker", loopType: .turnBased, checkDescription: "builds",
          firstInstruction: "Work")))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Critic", loopType: .turnBased, checkDescription: "honest",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    let maker = nodes[0].id
    let critic = nodes[1].id
    await store.handle(.createEdge(from: maker, to: critic, spec: EdgeSpec()))
    await store.handle(
      .createEdge(from: critic, to: maker, spec: EdgeSpec(cycleGuard: guardSpec)))
    return (Fixture(store: store, delivered: delivered, memory: memory), maker, critic)
  }

  // MARK: - Nudges on cycle re-entry

  @Test
  func cycleReentryNudgesTheLiveTargetSession() async {
    let (fixture, maker, critic) = await makerCriticFixture(
      guardSpec: CycleGuard(maxIterations: 3))

    await fixture.store.handle(.nodeCheckApproved(maker))
    await fixture.store.handle(.nodeCheckRejected(critic))

    // The guarded edge fired back into the maker: it must have been *told*, not just
    // reset — a live session hears nothing from state bookkeeping alone.
    let nudges = fixture.delivered.value.filter { $0.title == "Maker" }
    #expect(nudges.count == 1)
    #expect(nudges[0].text.contains("Cycle re-entry 1 of 3"))
    #expect(nudges[0].text.contains("stop condition is not yet met"))
  }

  @Test
  func undeliverableHandoffIsStagedIntoMemoryNotDropped() async {
    let (fixture, maker, critic) = await makerCriticFixture(
      guardSpec: CycleGuard(maxIterations: 3), deliverySucceeds: false)

    await fixture.store.handle(.nodeCheckApproved(maker))
    await fixture.store.handle(.nodeCheckRejected(critic))

    let staged = fixture.memory.value.filter {
      $0.nodeID == maker && $0.entry.contains("while you were away")
    }
    #expect(staged.count == 1)
  }

  @Test
  func plainHandoffDeliveryNamesTheSource() async {
    let (fixture, maker, critic) = await makerCriticFixture(
      guardSpec: CycleGuard(maxIterations: 3))

    await fixture.store.handle(.nodeCheckApproved(maker))

    let toCritic = fixture.delivered.value.filter { $0.title == "Critic" }
    #expect(toCritic.count == 1)
    #expect(toCritic[0].text.contains("Maker finished"))
  }

  // MARK: - Handoff payloads

  @Test
  func scriptPayloadRidesTheHandoff() async {
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onCaptureScript: { _ in "3 files changed, 40 insertions" })

    await store.handle(
      .createNode(
        NodeDraft(
          title: "Maker", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Critic", loopType: .turnBased, checkDescription: "y",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(
      .createEdge(
        from: nodes[0].id, to: nodes[1].id,
        spec: EdgeSpec(payloadTransform: .script("git diff --stat"))))

    await store.handle(.nodeCheckApproved(nodes[0].id))

    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].contains("3 files changed, 40 insertions"))
  }

  // MARK: - Metric capture and the plateau bound

  /// Drives one full maker→critic pass: approve the maker, reject the critic, which
  /// fires the guarded edge and (unless stopped) re-enters the cycle.
  private func runPass(_ fixture: Fixture, maker: UUID, critic: UUID) async {
    await fixture.store.handle(.nodeCheckApproved(maker))
    await fixture.store.handle(.nodeCheckRejected(critic))
  }

  @Test
  func metricIsSampledOncePerPassOntoTheSourceNode() async {
    let store = GraphStore(
      onCaptureScript: { _ in "some output\n41" },
      onAppendMemory: { _, _ in })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Critic", loopType: .goalBased,
          goal: GoalSpec(summary: "quality", metricCommand: "count-failures"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Maker", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    let critic = nodes[0].id
    let maker = nodes[1].id
    await store.handle(.createEdge(from: maker, to: critic, spec: EdgeSpec()))
    await store.handle(
      .createEdge(from: critic, to: maker, spec: EdgeSpec(cycleGuard: CycleGuard(maxIterations: 4)))
    )

    // Resolve the critic (session-exit path is a check here); the guarded edge fires
    // and the pass boundary samples its metric — last stdout line, parsed as a number.
    await store.handle(.nodeCheckApproved(critic))

    let history = await store.graph.nodes[id: critic]?.metricHistory ?? []
    #expect(history.map(\.value) == [41])
  }

  @Test
  func plateauStopsTheCycleInsteadOfReFiring() async {
    // The metric never improves: every pass reads the same number.
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onCaptureScript: { _ in "41" },
      onAppendMemory: { nodeID, entry in memory.withValue { $0.append((nodeID, entry)) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Critic", loopType: .goalBased,
          goal: GoalSpec(
            summary: "quality", metricCommand: "count-failures", metricDirection: .minimize))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Maker", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    let critic = nodes[0].id
    let maker = nodes[1].id
    await store.handle(.createEdge(from: maker, to: critic, spec: EdgeSpec()))
    await store.handle(
      .createEdge(
        from: critic, to: maker,
        spec: EdgeSpec(
          cycleGuard: CycleGuard(maxIterations: 10, stopAfterPassesWithoutImprovement: 2))))

    // Pass 1: sample 41, no baseline yet — re-fires. Passes 2 and 3: flat against the
    // best before them; after two flat passes the plateau bound stops the cycle.
    await store.handle(.nodeCheckApproved(critic))
    await store.handle(.nodeCheckApproved(critic))
    await store.handle(.nodeCheckApproved(critic))

    let backEdge = await store.graph.edges.first { $0.from == critic && $0.to == maker }
    #expect(backEdge?.fireCount == 2)
    #expect(memory.value.contains { $0.entry.contains("no improvement across 2 passes") })
  }

  @Test
  func anImprovingMetricKeepsTheCycleAlive() async {
    let readings = LockIsolated<[String]>(["41", "22", "9"])
    let store = GraphStore(
      onCaptureScript: { _ in readings.withValue { $0.isEmpty ? "9" : $0.removeFirst() } },
      onAppendMemory: { _, _ in })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Critic", loopType: .goalBased,
          goal: GoalSpec(
            summary: "quality", metricCommand: "count-failures", metricDirection: .minimize))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Maker", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    let critic = nodes[0].id
    let maker = nodes[1].id
    await store.handle(.createEdge(from: maker, to: critic, spec: EdgeSpec()))
    await store.handle(
      .createEdge(
        from: critic, to: maker,
        spec: EdgeSpec(
          cycleGuard: CycleGuard(maxIterations: 10, stopAfterPassesWithoutImprovement: 1))))

    await store.handle(.nodeCheckApproved(critic))
    await store.handle(.nodeCheckApproved(critic))
    await store.handle(.nodeCheckApproved(critic))

    // 41 → 22 → 9 under .minimize: every pass improves, so all three re-fire.
    let backEdge = await store.graph.edges.first { $0.from == critic && $0.to == maker }
    #expect(backEdge?.fireCount == 3)
  }

  @Test
  func aPlateauOnlyGuardCountsAsBounded() {
    #expect(CycleGuard(stopAfterPassesWithoutImprovement: 2).isBounded)
    #expect(!CycleGuard().isBounded)
  }

  // MARK: - MetricTrend

  @Test
  func metricTrendParsesTheLastNumericLine() {
    #expect(MetricTrend.value(fromScriptOutput: "noise\n42.5\n") == 42.5)
    #expect(MetricTrend.value(fromScriptOutput: "no numbers here") == nil)
    #expect(MetricTrend.value(fromScriptOutput: "") == nil)
  }

  @Test
  func plateauNeedsABaselineBeforeItCanTrigger() {
    #expect(!MetricTrend.plateaued([41], direction: .minimize, passes: 2))
    #expect(!MetricTrend.plateaued([41, 41], direction: .minimize, passes: 2))
    #expect(MetricTrend.plateaued([41, 41, 41], direction: .minimize, passes: 2))
    #expect(!MetricTrend.plateaued([41, 41, 30], direction: .minimize, passes: 2))
    #expect(MetricTrend.plateaued([10, 9, 9], direction: .minimize, passes: 1))
    #expect(!MetricTrend.plateaued([10, 11, 12], direction: .maximize, passes: 1))
  }

  // MARK: - updateNode

  @Test
  func updateAppliesObserverSideFieldsAndRecordsProvenance() async {
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onEvaluatePredicate: { _ in false },
      onAppendMemory: { nodeID, entry in memory.withValue { $0.append((nodeID, entry)) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .goalBased,
          goal: GoalSpec(summary: "tests pass", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(
      .updateNode(nodeID, update: NodeUpdate(goalPredicate: "make check", stallAfterSeconds: 600)))

    let goal = await store.graph.nodes[id: nodeID]?.goal
    #expect(goal?.predicate == "make check")
    #expect(goal?.stallAfterSeconds == 600)
    #expect(memory.value.contains { $0.entry.contains("updated by a human") })
  }

  @Test
  func aLoopMayNotChangeItsOwnStopCondition() async {
    let store = GraphStore(onEvaluatePredicate: { _ in false }, onAppendMemory: { _, _ in })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .goalBased,
          goal: GoalSpec(summary: "tests pass", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(
      .updateNode(nodeID, update: NodeUpdate(goalPredicate: "true", updatedBy: nodeID)))

    // Refused, not applied: the verifier stays outside the verified.
    let goal = await store.graph.nodes[id: nodeID]?.goal
    #expect(goal?.predicate == "make test")
  }

  @Test
  func aPeerLoopMayProposeAStopConditionChange() async {
    let store = GraphStore(onEvaluatePredicate: { _ in false }, onAppendMemory: { _, _ in })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .goalBased,
          goal: GoalSpec(summary: "tests pass", predicate: "make test"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Engineer", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes

    await store.handle(
      .updateNode(
        nodes[0].id, update: NodeUpdate(goalPredicate: "make check", updatedBy: nodes[1].id)))

    let goal = await store.graph.nodes[id: nodes[0].id]?.goal
    #expect(goal?.predicate == "make check")
  }

  @Test
  func sessionFacingUpdatesNudgeTheLiveSession() async {
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      onEvaluatePredicate: { _ in false },
      onDeliverMessage: { _, text, _ in
        delivered.withValue { $0.append(text) }
        return true
      },
      onAppendMemory: { _, _ in })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(
      .updateNode(nodeID, update: NodeUpdate(goalSummary: "tests pass on CI too")))

    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].contains("instructions were revised"))
    #expect(delivered.value[0].contains("tests pass on CI too"))
  }

  @Test
  func anEmptyGoalSummaryIsRefused() async {
    let store = GraphStore(onEvaluatePredicate: { _ in false })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.updateNode(nodeID, update: NodeUpdate(goalSummary: "   ")))

    let goal = await store.graph.nodes[id: nodeID]?.goal
    #expect(goal?.summary == "tests pass")
  }

  // MARK: - Memos

  @Test
  func aMemoLandsInTheNodesMemoryLog() async {
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onAppendMemory: { nodeID, entry in memory.withValue { $0.append((nodeID, entry)) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Fixer", loopType: .turnBased, checkDescription: "x",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(
      .memoNode(nodeID, text: "retry-with-backoff was a dead end", from: nodeID))

    let notes = memory.value.filter { $0.nodeID == nodeID && $0.entry.hasPrefix("note") }
    #expect(notes.count == 1)
    #expect(notes[0].entry == "note: retry-with-backoff was a dead end")
  }

  // MARK: - NodeMemory files

  @Test
  func nodeMemoryAppendsAndDigestsWithinBudget() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-memory-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let nodeID = UUID()

    // No memory yet → no wake file: a first launch must not be told to read nothing.
    #expect(NodeMemory.writeWakeDigest(projectPath: "/tmp/p", nodeID: nodeID, baseURL: base) == nil)

    for index in 1...(NodeMemory.wakeLineBudget + 5) {
      NodeMemory.append("entry \(index)", projectPath: "/tmp/p", nodeID: nodeID, baseURL: base)
    }
    let entries = NodeMemory.entries(forProjectPath: "/tmp/p", nodeID: nodeID, baseURL: base)
    #expect(entries.count == NodeMemory.wakeLineBudget + 5)
    #expect(entries[0].hasSuffix("entry 1"))

    let wake = try #require(
      NodeMemory.writeWakeDigest(projectPath: "/tmp/p", nodeID: nodeID, baseURL: base))
    let digest = try String(contentsOf: wake, encoding: .utf8)
    #expect(digest.contains("5 earlier entries elided"))
    #expect(digest.contains("entry \(NodeMemory.wakeLineBudget + 5)"))
    #expect(!digest.contains("entry 1\n"))

    NodeMemory.remove(projectPath: "/tmp/p", nodeID: nodeID, baseURL: base)
    #expect(NodeMemory.entries(forProjectPath: "/tmp/p", nodeID: nodeID, baseURL: base).isEmpty)
  }

  @Test
  func nodeMemoryFlattensNewlinesSoTheLogStaysLineOriented() {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-memory-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let nodeID = UUID()

    NodeMemory.append("line one\nline two", projectPath: "/tmp/p", nodeID: nodeID, baseURL: base)

    let entries = NodeMemory.entries(forProjectPath: "/tmp/p", nodeID: nodeID, baseURL: base)
    #expect(entries.count == 1)
    #expect(entries[0].contains("line one line two"))
  }
}
