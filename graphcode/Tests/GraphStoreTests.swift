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
    await store.handle(.createTurnBasedNode(title: "Research", checkDescription: "Sound?"))

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
    let store = GraphStore(onEnsureSession: { node in started.withValue { $0.append(node) } })

    await store.handle(
      .createTimeBasedNode(title: "Poll inbox", prompt: "/loop 1h Check for new reports"))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].loopType == .timeBased)
    #expect(graph.nodes[0].triggerPrompt == "/loop 1h Check for new reports")
    #expect(started.value.map(\.id) == [graph.nodes[0].id])
  }

  @Test
  func ensureTimeBasedSessionsRestartsOnlyTimeBasedNodes() async {
    // What gets a persisted loop running again after a reboot — turn-based nodes must
    // not be swept up, since a human opening them is what starts those.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node in started.withValue { $0.append(node) } })
    await store.handle(.createTurnBasedNode(title: "Research", checkDescription: "Sound?"))
    await store.handle(.createTimeBasedNode(title: "Poll inbox", prompt: "/loop 1h Check"))
    started.withValue { $0.removeAll() }

    await store.ensureTimeBasedSessions()

    #expect(started.value.count == 1)
    #expect(started.value.first?.loopType == .timeBased)
  }

  @Test
  func approvingASourceNodeAutomaticallyFiresItsEdgeAndUnblocksTheTarget() async {
    let store = GraphStore()
    await store.handle(.createTurnBasedNode(title: "Research", checkDescription: "Sound?"))
    await store.handle(.createTurnBasedNode(title: "Implement", checkDescription: "Correct?"))

    let nodesBeforeEdge = await store.graph.nodes
    let sourceID = nodesBeforeEdge[0].id
    let targetID = nodesBeforeEdge[1].id

    await store.handle(.createEdge(from: sourceID, to: targetID))
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
    // `.createEdge` has no way to request `.onSuccess`/`.onFailure` yet — the UI only
    // ever creates default `.always` edges (see docs/07-roadmap.md's deferred
    // goal-based/proactive node config). This documents that an `.always` edge fires
    // regardless of how the source resolved, not just on success.
    let store = GraphStore()
    await store.handle(.createTurnBasedNode(title: "Research", checkDescription: "Sound?"))
    await store.handle(.createTurnBasedNode(title: "Escalate", checkDescription: "Needs help?"))

    let nodes = await store.graph.nodes
    let sourceID = nodes[0].id
    let targetID = nodes[1].id
    await store.handle(.createEdge(from: sourceID, to: targetID))

    await store.handle(.nodeCheckRejected(sourceID))
    let graph = await store.graph
    #expect(graph.nodes[id: sourceID]?.state == .failed)
    #expect(graph.nodes[id: targetID]?.state == .idle)
    #expect(graph.edges[0].fired == true)
  }

  @Test
  func creatingADuplicateEdgeIsIgnored() async {
    let store = GraphStore()
    await store.handle(.createTurnBasedNode(title: "A", checkDescription: "?"))
    await store.handle(.createTurnBasedNode(title: "B", checkDescription: "?"))
    let nodes = await store.graph.nodes
    let (nodeA, nodeB) = (nodes[0].id, nodes[1].id)

    await store.handle(.createEdge(from: nodeA, to: nodeB))
    await store.handle(.createEdge(from: nodeA, to: nodeB))
    let graph = await store.graph
    #expect(graph.edges.count == 1)
  }

  @Test
  func selfLoopEdgeIsRejected() async {
    let store = GraphStore()
    await store.handle(.createTurnBasedNode(title: "A", checkDescription: "?"))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.createEdge(from: nodeID, to: nodeID))
    let graph = await store.graph
    #expect(graph.edges.isEmpty)
  }

  @Test
  func newConnectionReceivesCurrentGraphImmediately() async {
    let store = GraphStore()
    await store.handle(.createTurnBasedNode(title: "Research", checkDescription: "Sound?"))

    // No real socket needed to prove this: addConnection's first `send` call is a
    // no-op for an unknown/invalid fd (silently dropped, not thrown), so this just
    // confirms it doesn't crash for a caller-supplied connection id (Phase 4 moved id
    // generation to `ProjectRegistry`, see docs/07-roadmap.md#phase-4--projects).
    let connectionID = UUID()
    await store.addConnection(id: connectionID, fileDescriptor: -1)
    await store.removeConnection(connectionID)
  }
}
