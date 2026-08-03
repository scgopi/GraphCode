import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit

/// Phase 6's last three pieces: composites, the pilot-before-arm gate, and the
/// global Orchestrator Graph's cross-graph `.spawn`.
@Suite
struct CompositeAndGlobalGraphTests {
  private func storeWithComposite(
    pilotState: PilotState = .notPiloted,
    subNodes: [LoopNode] = [],
    onEnsureSession: (@Sendable (LoopNode, String?) -> Void)? = nil
  ) async -> (store: GraphStore, compositeID: UUID) {
    let composite = LoopNode(
      title: "Triage inbox", loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: IdentifiedArray(uniqueElements: subNodes)),
      pilotState: pilotState)
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [composite]),
      onEnsureSession: onEnsureSession)
    return (store, composite.id)
  }

  // MARK: - Composites

  @Test
  func anUnpilotedCompositeDoesNotClaimToBeRunning() async {
    // A goal loop is born `.running`, so the first one added rolled its composite up to
    // RUNNING while `pilotState` still read "Not piloted" and not one process existed.
    // The card said the routine was working; the pilot gate is the promise that it isn't.
    let (store, compositeID) = await storeWithComposite()

    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(
            title: "Draft reply", loopType: .goalBased,
            goal: GoalSpec(summary: "Every item has a reply")))))

    let composite = await store.graph.nodes[id: compositeID]
    #expect(composite?.subGraph?.nodes.count == 1)
    #expect(composite?.state != .running)
  }

  @Test
  func aCompositeInsideACompositeCanBeAddressedDirectly() async throws {
    // Ids are unique across the whole tree, so naming a nested composite must be enough —
    // spelling out the chain of parents to reach it is not something a caller can be
    // expected to do. This went nowhere at all: the command was dropped in silence.
    let (store, outerID) = await storeWithComposite()
    await store.handle(
      .subGraphCommand(
        nodeID: outerID, command: .createNode(NodeDraft(title: "Inner", loopType: .composite))))

    let innerID = try #require(await store.graph.nodes[id: outerID]?.subGraph?.nodes.first?.id)
    await store.handle(
      .subGraphCommand(
        nodeID: innerID,
        command: .createNode(
          NodeDraft(title: "Deep", loopType: .timeBased, triggerPrompt: "/loop 1h deep"))))

    let inner = await store.graph.nodes[id: outerID]?.subGraph?.nodes[id: innerID]
    #expect(inner?.subGraph?.nodes.map(\.title) == ["Deep"])
  }

  @Test
  func addingALoopInsideACompositeDoesNotStartIt() async {
    // `createNode` starts a session for every unattended loop it makes, which is right
    // on a project canvas and wrong inside a composite: a loop in a sub-graph is a
    // template until the composite is piloted. Forwarding the callback would have adding
    // a loop launch it on the spot — the un-piloted, un-armed running `PilotState` exists
    // to prevent, and it would fire from a dialog that says "Nothing runs when you press
    // Create."
    let started = LockIsolated<[String]>([])
    let (store, compositeID) = await storeWithComposite(
      onEnsureSession: { node, _ in started.withValue { $0.append(node.title) } })

    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(title: "Sweep", loopType: .timeBased, triggerPrompt: "/loop 1h Check"))))

    #expect(await store.graph.nodes[id: compositeID]?.subGraph?.nodes.count == 1)
    #expect(started.value.isEmpty)
  }

  @Test
  func aSubGraphIsOrchestratedByTheSameRulesAsAnyGraph() async {
    // "No separate execution engine" — a composite's insides take the very same commands
    // and fire edges the same way.
    let (store, compositeID) = await storeWithComposite()

    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(
            title: "Classify", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))
    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(
            title: "Draft reply", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))

    let sub = try? #require(await store.graph.nodes[id: compositeID]?.subGraph)
    #expect(sub?.nodes.count == 2)

    let subNodes = sub?.nodes.map(\.id) ?? []
    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createEdge(from: subNodes[0], to: subNodes[1], spec: EdgeSpec())))

    let afterEdge = await store.graph.nodes[id: compositeID]?.subGraph
    #expect(afterEdge?.edges.count == 1)
    // Edge semantics apply inside a composite exactly as outside it.
    #expect(afterEdge?.nodes[id: subNodes[1]]?.state == .blocked)
  }

  @Test
  func aCompositesStateIsItsSubGraphsAggregate() async {
    // The roll-up docs/05 asks for: the parent reports what's happening inside it.
    let running = LoopNode(title: "Worker", state: .running)
    let (store, compositeID) = await storeWithComposite(subNodes: [running])

    // Any sub-graph command triggers a roll-up; creating a node is the cheapest one.
    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(
            title: "Another", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))

    #expect(await store.graph.nodes[id: compositeID]?.state == .running)
  }

  @Test
  func aFinishedSubGraphResolvesTheParentAndFiresItsEdges() async {
    // This is what lets a composite sit in an ordinary graph and hand off like any other
    // node — the whole reason the roll-up has to reach a real resolution.
    let done = LoopNode(title: "Worker", state: .succeeded)
    let composite = LoopNode(
      title: "Triage", loopType: .composite,
      subGraph: LoopGraph(project: ProjectRef(path: "sub", name: "sub"), nodes: [done]))
    let downstream = LoopNode(title: "Report", checkDescription: "?")
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [composite, downstream],
        edges: [LoopEdge(from: composite.id, to: downstream.id)]))

    // Any sub-graph command re-rolls the parent; `.refreshUsage` is the one that changes
    // nothing else, so what's under test here is purely the roll-up.
    await store.handle(.subGraphCommand(nodeID: composite.id, command: .refreshUsage))

    let graph = await store.graph
    #expect(graph.nodes[id: composite.id]?.state == .succeeded)
    #expect(graph.edges[0].fired == true)
    #expect(graph.nodes[id: downstream.id]?.state == .idle)
  }

  @Test
  func aSubGraphCommandAimedAtANonCompositeIsIgnored() async {
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Plain", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(
      .subGraphCommand(
        nodeID: nodeID,
        command: .createNode(
          NodeDraft(
            title: "Sneaky", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))

    #expect(await store.graph.nodes.count == 1)
    #expect(await store.graph.nodes[0].subGraph == nil)
  }

  // MARK: - Pilot before arm

  @Test
  func aCompositeCannotBeArmedBeforeItIsPiloted() async {
    // docs/08: the dry run is the path of least resistance, not a step you can forget.
    let (store, compositeID) = await storeWithComposite()

    await store.handle(.armComposite(compositeID))

    #expect(await store.graph.nodes[id: compositeID]?.pilotState == .notPiloted)
    #expect(await store.graph.nodes[id: compositeID]?.state != .running)
  }

  @Test
  func pilotingRunsTheSubGraphForRealThenAllowsArming() async {
    // "Run once now, on a small slice" — real sessions, real cost, just not wired to the
    // recurring trigger yet.
    let started = LockIsolated<[LoopNode]>([])
    let worker = LoopNode(
      title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check")
    let (store, compositeID) = await storeWithComposite(
      subNodes: [worker],
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(.pilotComposite(compositeID))

    #expect(await store.graph.nodes[id: compositeID]?.pilotState == .piloted)
    #expect(started.value.map(\.title) == ["Worker"])

    await store.handle(.armComposite(compositeID))
    #expect(await store.graph.nodes[id: compositeID]?.pilotState == .armed)
    #expect(await store.graph.nodes[id: compositeID]?.state == .running)
  }

  @Test
  func pilotingANodeWithNoSubGraphDoesNothing() async {
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Plain", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.pilotComposite(nodeID))

    #expect(await store.graph.nodes[0].pilotState == .notPiloted)
  }

  // MARK: - Global graph and cross-graph spawn

  @Test
  func theReservedPathRoundTripsToTheGlobalScope() {
    #expect(LoopGraphScope(projectPath: LoopGraphScope.globalPath, name: "x") == .global)
    #expect(LoopGraph(scope: .global).isGlobal)
    #expect(LoopGraph(scope: .global).project.path == LoopGraphScope.globalPath)
    // A real folder is never mistaken for it.
    #expect(!LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")).isGlobal)
  }

  @Test
  func aGlobalGraphSurvivesTheRoundTripThroughPersistence() throws {
    // It's persisted as an ordinary `ProjectRef`, so the reserved path is what carries
    // its identity back.
    let graph = LoopGraph(scope: .global, nodes: [LoopNode(title: "Watch inbox")])
    let decoded = try JSONDecoder().decode(
      LoopGraph.self, from: JSONEncoder().encode(graph))

    #expect(decoded.isGlobal)
    #expect(decoded.nodes.count == 1)
  }

  @Test
  func aCrossGraphSpawnHandsADraftUpRatherThanInstantiatingLocally() async {
    // The global graph can't reach a project's store, so it hands the request to the
    // registry. A draft travels, not a node — the receiving graph mints its own id and
    // applies its own validation.
    let requests = LockIsolated<[(path: String, draft: NodeDraft)]>([])
    let trigger = LoopNode(title: "Watch inbox", state: .idle)
    let template = LoopNode(
      title: "Triage bug", loopType: .turnBased, checkDescription: "Classified?",
      modelTier: .fast)
    let store = GraphStore(
      graph: LoopGraph(
        scope: .global,
        nodes: [trigger, template],
        edges: [
          LoopEdge(
            from: trigger.id, to: template.id, kind: .spawn,
            spawnTargetProjectPath: "/tmp/target")
        ]),
      onSpawnIntoProject: { path, draft in
        requests.withValue { $0.append((path, draft)) }
      })

    await store.handle(.nodeCheckApproved(trigger.id))

    #expect(requests.value.count == 1)
    #expect(requests.value.first?.path == "/tmp/target")
    #expect(requests.value.first?.draft.title == "Triage bug")
    #expect(requests.value.first?.draft.modelTier == .fast)
    // Nothing was created locally — the work belongs in the other graph.
    #expect(await store.graph.nodes.count == 2)
  }

  @Test
  func anIntraGraphSpawnStillInstantiatesLocally() async {
    // Only an edge that names a target project crosses; everything else behaves as it
    // did before the global graph existed.
    let trigger = LoopNode(title: "Trigger", state: .idle)
    let template = LoopNode(title: "Worker", checkDescription: "?")
    let requests = LockIsolated(0)
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [trigger, template],
        edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)]),
      onSpawnIntoProject: { _, _ in requests.withValue { $0 += 1 } })

    await store.handle(.nodeCheckApproved(trigger.id))

    #expect(requests.value == 0)
    #expect(await store.graph.nodes.count == 3)
  }

  // MARK: - Usage

  @Test
  func usageIsReadFromTheBackendNotEstimated() async {
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [LoopNode(title: "A"), LoopNode(title: "B")]),
      onReadUsage: { node in
        node.title == "A" ? UsageSample(inputTokens: 100, outputTokens: 50, costUSD: 0.02) : nil
      })

    await store.handle(.refreshUsage)

    let graph = await store.graph
    #expect(graph.nodes[0].usage?.totalTokens == 150)
    // B's backend reported nothing, so B has no usage — not a zero nobody measured.
    #expect(graph.nodes[1].usage == nil)
    #expect(graph.usage?.costUSD == 0.02)
    #expect(graph.usageCoverage.reporting == 1)
    #expect(graph.usageCoverage.total == 2)
  }

  @Test
  func aGraphWhereNothingReportedRollsUpToNilNotZero() {
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [LoopNode(title: "A")])

    #expect(graph.usage == nil)
  }

  @Test
  func usageLabelsParseAsSubsets() {
    // A backend reporting only part of the picture still contributes what it has.
    #expect(UsageSample.parse("inputTokens=10 outputTokens=20")?.totalTokens == 30)
    #expect(UsageSample.parse("cost=0.5")?.costUSD == 0.5)
    #expect(UsageSample.parse("inputTokens=10")?.costUSD == nil)
    // Unknown keys are ignored rather than rejected.
    #expect(UsageSample.parse("somethingElse=9 output=4")?.outputTokens == 4)
  }

  @Test
  func anUnparseableUsageLabelIsNilNotZero() {
    // The failure that matters: a garbage label becoming a confident "$0.00 spent".
    #expect(UsageSample.parse("") == nil)
    #expect(UsageSample.parse("garbage") == nil)
    #expect(UsageSample.parse("inputTokens=notanumber") == nil)
  }

  @Test
  func usageAddsAcrossNodesWithoutInventingMissingFields() {
    let tokensOnly = UsageSample(inputTokens: 10, costUSD: 1)
    let outputOnly = UsageSample(outputTokens: 5)
    let sum = tokensOnly + outputOnly

    #expect(sum.inputTokens == 10)
    #expect(sum.outputTokens == 5)
    #expect(sum.costUSD == 1)
  }
}
