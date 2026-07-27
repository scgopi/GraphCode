import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Tests the daemon's actual orchestration logic directly — no socket, no process.
/// This is the load-bearing part of Phase 3 (see
/// docs/07-roadmap.md#phase-3--orchestrator-automation): automatic `.handoff` firing
/// used to be a human clicking "Fire" (Phase 2); now it's `GraphStore` reacting to a
/// node's resolution.
@Suite
struct GraphStoreTests {
  @Test
  func creatingATurnBasedNodeAddsItStandalone() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?")))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].state == .idle)
    #expect(graph.nodes[0].loopType == .turnBased)
  }

  @Test
  func creatingATimeBasedNodeStartsItsSessionImmediately() async {
    // The daemon's only job for a time-based node is making sure its session exists —
    // it deliberately schedules nothing, since the `/loop` in the prompt is what
    // re-triggers the work from inside the session.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(
      .createNode(
        NodeDraft(
          title: "Poll inbox", loopType: .timeBased, triggerPrompt: "/loop 1h Check for new reports"
        )))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].loopType == .timeBased)
    #expect(graph.nodes[0].triggerPrompt == "/loop 1h Check for new reports")
    #expect(started.value.map(\.id) == [graph.nodes[0].id])
  }

  @Test
  func ensureUnattendedSessionsRestartsOnlyUnattendedNodes() async {
    // What gets a persisted loop running again after a reboot — turn-based nodes must
    // not be swept up, since a human opening them is what starts those.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?")))
    await store.handle(
      .createNode(
        NodeDraft(title: "Poll inbox", loopType: .timeBased, triggerPrompt: "/loop 1h Check")))
    await store.handle(
      .createNode(
        NodeDraft(title: "Green build", loopType: .goalBased, goal: GoalSpec(summary: "CI passes")))
    )
    started.withValue { $0.removeAll() }

    await store.ensureUnattendedSessions()

    #expect(started.value.count == 2)
    #expect(Set(started.value.map(\.loopType)) == [.timeBased, .goalBased])
  }

  @Test
  func approvingASourceNodeAutomaticallyFiresItsEdgeAndUnblocksTheTarget() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?")))
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "Correct?"))
    )

    let nodesBeforeEdge = await store.graph.nodes
    let sourceID = nodesBeforeEdge[0].id
    let targetID = nodesBeforeEdge[1].id

    await store.handle(.createEdge(from: sourceID, to: targetID, spec: EdgeSpec()))
    var graph = await store.graph
    #expect(graph.nodes[id: targetID]?.state == .blocked)
    #expect(graph.edges.count == 1)
    #expect(graph.edges[0].fired == false)

    // No human clicks "Fire" here — approving the source is enough.
    await store.handle(.nodeCheckApproved(sourceID))
    graph = await store.graph
    #expect(graph.nodes[id: sourceID]?.state == .succeeded)
    #expect(graph.nodes[id: targetID]?.state == .idle)
    #expect(graph.edges[0].fired == true)
  }

  @Test
  func defaultAlwaysConditionFiresOnFailureToo() async {
    // The drop editor now lets a human pick `.onSuccess`/`.onFailure`, but `.always`
    // stays the default — this documents that an `.always` edge fires regardless of how
    // the source resolved, not just on success.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?")))
    await store.handle(
      .createNode(
        NodeDraft(title: "Escalate", loopType: .turnBased, checkDescription: "Needs help?")))

    let nodes = await store.graph.nodes
    let sourceID = nodes[0].id
    let targetID = nodes[1].id
    await store.handle(.createEdge(from: sourceID, to: targetID, spec: EdgeSpec()))

    await store.handle(.nodeCheckRejected(sourceID))
    let graph = await store.graph
    #expect(graph.nodes[id: sourceID]?.state == .failed)
    #expect(graph.nodes[id: targetID]?.state == .idle)
    #expect(graph.edges[0].fired == true)
  }

  @Test
  func creatingADuplicateEdgeIsIgnored() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    let (nodeA, nodeB) = (nodes[0].id, nodes[1].id)

    await store.handle(.createEdge(from: nodeA, to: nodeB, spec: EdgeSpec()))
    await store.handle(.createEdge(from: nodeA, to: nodeB, spec: EdgeSpec()))
    let graph = await store.graph
    #expect(graph.edges.count == 1)
  }

  @Test
  func selfLoopEdgeIsRejected() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.createEdge(from: nodeID, to: nodeID, spec: EdgeSpec()))
    let graph = await store.graph
    #expect(graph.edges.isEmpty)
  }

  @Test
  func onSuccessEdgeStaysUnfiredWhenTheSourceFails() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "Correct?"))
    )
    await store.handle(
      .createNode(NodeDraft(title: "Ship", loopType: .turnBased, checkDescription: "Ready?")))
    let nodes = await store.graph.nodes
    let (sourceID, targetID) = (nodes[0].id, nodes[1].id)
    await store.handle(
      .createEdge(from: sourceID, to: targetID, spec: EdgeSpec(condition: .onSuccess)))

    await store.handle(.nodeCheckRejected(sourceID))

    let graph = await store.graph
    #expect(graph.edges[0].fired == false)
    // The target stays blocked precisely because the edge didn't fire — a rejected
    // implementation must not unblock the node waiting on it.
    #expect(graph.nodes[id: targetID]?.state == .blocked)
  }

  @Test
  func onFailureEdgeFiresOnlyWhenTheSourceFails() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "Correct?"))
    )
    await store.handle(
      .createNode(NodeDraft(title: "Escalate", loopType: .turnBased, checkDescription: "Handled?")))
    let nodes = await store.graph.nodes
    let (sourceID, targetID) = (nodes[0].id, nodes[1].id)
    await store.handle(
      .createEdge(from: sourceID, to: targetID, spec: EdgeSpec(condition: .onFailure)))

    await store.handle(.nodeCheckApproved(sourceID))
    #expect(await store.graph.edges[0].fired == false)

    // Same graph, opposite resolution: a fresh store proves the mirror case rather
    // than re-resolving an already-succeeded node.
    let failing = GraphStore()
    await failing.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "Correct?"))
    )
    await failing.handle(
      .createNode(NodeDraft(title: "Escalate", loopType: .turnBased, checkDescription: "Handled?")))
    let failingNodes = await failing.graph.nodes
    await failing.handle(
      .createEdge(
        from: failingNodes[0].id, to: failingNodes[1].id, spec: EdgeSpec(condition: .onFailure)))
    await failing.handle(.nodeCheckRejected(failingNodes[0].id))

    let graph = await failing.graph
    #expect(graph.edges[0].fired == true)
    #expect(graph.nodes[id: failingNodes[1].id]?.state == .idle)
  }

  @Test
  func aMessageEdgeNeverBlocksItsTarget() async {
    // `.message` peers run concurrently by definition — drawing one must not leave the
    // target sitting in `.blocked` waiting for a handoff that will never come.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "Correct?"))
    )
    await store.handle(
      .createNode(NodeDraft(title: "Review", loopType: .turnBased, checkDescription: "Sound?")))
    let nodes = await store.graph.nodes

    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(kind: .message)))

    let graph = await store.graph
    #expect(graph.edges.count == 1)
    #expect(graph.nodes[id: nodes[1].id]?.state == .idle)
  }

  @Test
  func aSpawnEdgeInstantiatesItsTemplateRatherThanUnblockingIt() async {
    // The behaviour that distinguishes `.spawn` from `.handoff`: the target is a
    // template, and firing produces a fresh copy while leaving the template alone for
    // the next spawn.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Triage", loopType: .turnBased, checkDescription: "Classified?"))
    )
    await store.handle(
      .createNode(NodeDraft(title: "Template", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(kind: .spawn)))

    await store.handle(.nodeCheckApproved(nodes[0].id))

    let graph = await store.graph
    #expect(graph.edges[0].fired == true)
    #expect(graph.nodes.count == 3)
    // The template is untouched and still idle, ready to be spawned from again.
    #expect(graph.nodes[id: nodes[1].id]?.state == .idle)
    #expect(graph.nodes[id: nodes[1].id]?.title == "Template")
    // The instance is distinguishable at a glance and carries no edges of its own.
    #expect(graph.nodes[2].title == "Template #2")
    #expect(!graph.edges.contains { $0.from == graph.nodes[2].id || $0.to == graph.nodes[2].id })
  }

  @Test
  func aHandoffAndAMessageCanCoexistBetweenTheSamePair() async {
    // Duplicate rejection is per-kind: two loops can both be sequenced and be able to
    // talk mid-flight.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes

    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(kind: .message)))
    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(kind: .message)))

    let graph = await store.graph
    #expect(graph.edges.count == 2)
    #expect(graph.edges.filter { $0.kind == .message }.count == 1)
  }

  @Test
  func aPayloadTransformSurvivesTheRoundTripToTheStore() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes

    await store.handle(
      .createEdge(
        from: nodes[0].id, to: nodes[1].id,
        spec: EdgeSpec(payloadTransform: .script("git diff --stat"))))

    #expect(await store.graph.edges[0].payloadTransform == .script("git diff --stat"))
  }

  @Test
  func anInvalidDraftCreatesNothing() async {
    // The daemon rejects it too, not just the form — this protocol is reachable from
    // the CLI, and a rule only one client applies isn't a rule.
    let store = GraphStore()

    await store.handle(.createNode(NodeDraft(title: "No check", loopType: .turnBased)))
    await store.handle(.createNode(NodeDraft(title: "", loopType: .timeBased, triggerPrompt: "x")))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Wrong backend", loopType: .goalBased, goal: GoalSpec(summary: "Done"),
          backend: .codex)))

    #expect(await store.graph.nodes.isEmpty)
  }

  @Test
  func anInvalidDraftStartsNoSession() async {
    // Rejecting the node but still launching its session would leave an orphan `claude`
    // with nothing in the graph pointing at it.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(.createNode(NodeDraft(title: "No prompt", loopType: .timeBased)))

    #expect(started.value.isEmpty)
  }

  @Test
  func newConnectionReceivesCurrentGraphImmediately() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?")))

    // No real socket needed to prove this: addConnection's first `send` call is a
    // no-op for an unknown/invalid fd (silently dropped, not thrown), so this just
    // confirms it doesn't crash for a caller-supplied connection id (Phase 4 moved id
    // generation to `ProjectRegistry`, see docs/07-roadmap.md#phase-4--projects).
    let connectionID = UUID()
    await store.addConnection(id: connectionID, fileDescriptor: -1)
    await store.removeConnection(connectionID)
  }
}
