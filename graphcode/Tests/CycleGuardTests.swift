import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Cycle guards, and the re-firing they exist to bound
/// (docs/02-graph-of-loops.md, docs/08-quality-and-token-budgets.md).
///
/// The invariant these are really protecting: an *unguarded* edge behaves exactly as it
/// did before cycles existed — fires once, never re-enters. Repetition is opt-in, and
/// the thing you opt into is inseparable from its bound.
@Suite
struct CycleGuardTests {
  /// A → B → A, with the closing edge guarded.
  private struct Cycle {
    let store: GraphStore
    let nodeA: UUID
    let nodeB: UUID
  }

  private func twoNodeCycle(
    guard cycleGuard: CycleGuard,
    predicateMet: Bool = false
  ) async -> Cycle {
    let store = GraphStore(onEvaluatePredicate: { _ in predicateMet })
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "Review", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    let (nodeA, nodeB) = (nodes[0].id, nodes[1].id)
    await store.handle(.createEdge(from: nodeA, to: nodeB, spec: EdgeSpec()))
    await store.handle(
      .createEdge(from: nodeB, to: nodeA, spec: EdgeSpec(cycleGuard: cycleGuard)))
    return Cycle(store: store, nodeA: nodeA, nodeB: nodeB)
  }

  @Test
  func anUnguardedEdgeStillFiresExactlyOnce() async {
    // The regression that matters most: every graph built before cycle guards existed
    // has to keep behaving identically.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))

    await store.handle(.nodeCheckApproved(nodes[0].id))
    await store.handle(.nodeCheckApproved(nodes[0].id))

    #expect(await store.graph.edges[0].fireCount == 1)
  }

  @Test
  func anUnboundedGuardIsRefusedOutright() async {
    // A guard with neither a count nor a condition would make an unattended infinite
    // loop. Refusing the edge is louder than silently dropping the guard, which would
    // turn a loop the human asked for into a one-shot.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes

    await store.handle(
      .createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec(cycleGuard: CycleGuard())))

    #expect(await store.graph.edges.isEmpty)
  }

  @Test
  func aGuardedEdgeReentersTheCycleAndResetsItsMembers() async {
    let cycle = await twoNodeCycle(guard: CycleGuard(maxIterations: 3))
    let (store, nodeA, nodeB) = (cycle.store, cycle.nodeA, cycle.nodeB)

    // First pass.
    await store.handle(.nodeCheckApproved(nodeA))
    await store.handle(.nodeCheckApproved(nodeB))

    let graph = await store.graph
    // The next pass starts where the first one did: A is idle and ready to run, and B is
    // blocked behind it again — not idle, because it's waiting on A's handoff exactly as
    // it was before the first pass.
    #expect(graph.nodes[id: nodeA]?.state == .idle)
    #expect(graph.nodes[id: nodeB]?.state == .blocked)
    // ...the forward edge's count was cleared so it can carry the pass again...
    let forward = try? #require(graph.edges.first { $0.from == nodeA })
    #expect(forward?.fireCount == 0)
    // ...but the guarded edge's own count was not, because it's the bound.
    let closing = try? #require(graph.edges.first { $0.from == nodeB })
    #expect(closing?.fireCount == 1)
  }

  @Test
  func theIterationCapEventuallyStopsTheCycle() async {
    let cycle = await twoNodeCycle(guard: CycleGuard(maxIterations: 2))
    let (store, nodeA, nodeB) = (cycle.store, cycle.nodeA, cycle.nodeB)

    // Run more passes than the cap allows.
    for _ in 0..<5 {
      await store.handle(.nodeCheckApproved(nodeA))
      await store.handle(.nodeCheckApproved(nodeB))
    }

    let closing = await store.graph.edges.first { $0.from == nodeB }
    #expect(closing?.fireCount == 2)
    // Having spent its budget, the last pass leaves the cycle resolved rather than
    // reset — otherwise it would sit idle forever looking like it might still run.
    #expect(await store.graph.nodes[id: nodeB]?.state == .succeeded)
  }

  @Test
  func anUntilPredicateStopsTheCycleEarly() async {
    // Cap of 10, but the condition holds on the first check — so it never re-enters.
    let cycle = await twoNodeCycle(
      guard: CycleGuard(maxIterations: 10, until: "test -f done"), predicateMet: true)
    let (store, nodeA, nodeB) = (cycle.store, cycle.nodeA, cycle.nodeB)

    await store.handle(.nodeCheckApproved(nodeA))
    await store.handle(.nodeCheckApproved(nodeB))
    await store.handle(.nodeCheckApproved(nodeA))
    await store.handle(.nodeCheckApproved(nodeB))

    let closing = await store.graph.edges.first { $0.from == nodeB }
    // Fired once to start the cycle; every re-fire was vetoed by the predicate.
    #expect(closing?.fireCount == 1)
    #expect(await store.graph.nodes[id: nodeA]?.state == .succeeded)
  }

  @Test
  func anUnmetUntilPredicateLetsTheCycleContinue() async {
    let cycle = await twoNodeCycle(
      guard: CycleGuard(maxIterations: 10, until: "test -f done"), predicateMet: false)
    let (store, nodeA, nodeB) = (cycle.store, cycle.nodeA, cycle.nodeB)

    await store.handle(.nodeCheckApproved(nodeA))
    await store.handle(.nodeCheckApproved(nodeB))
    await store.handle(.nodeCheckApproved(nodeA))
    await store.handle(.nodeCheckApproved(nodeB))

    let closing = await store.graph.edges.first { $0.from == nodeB }
    #expect(closing?.fireCount == 2)
  }

  @Test
  func reenteringRelaunchesAnUnattendedNodesSession() async {
    // A time-based node on a cycle has to actually start again on the next pass — its
    // session ended when it resolved, and nothing else would revive it.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } },
      onEvaluatePredicate: { _ in false })
    await store.handle(
      .createNode(
        NodeDraft(title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check")))
    await store.handle(
      .createNode(NodeDraft(title: "Review", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    let (poll, review) = (nodes[0].id, nodes[1].id)
    await store.handle(.createEdge(from: poll, to: review, spec: EdgeSpec()))
    await store.handle(
      .createEdge(
        from: review, to: poll, spec: EdgeSpec(cycleGuard: CycleGuard(maxIterations: 3))))
    started.withValue { $0.removeAll() }

    await store.handle(.nodeCheckApproved(poll))
    await store.handle(.nodeCheckApproved(review))

    #expect(started.value.map(\.id) == [poll])
  }

  @Test
  func aConditionThatIsNotSatisfiedNeverStartsThePass() async {
    // An `.onSuccess` guarded edge must not re-enter on a failure — the guard governs
    // how many passes are allowed, not whether this one earned a pass.
    let store = GraphStore(onEvaluatePredicate: { _ in false })
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(
      .createEdge(
        from: nodes[1].id, to: nodes[0].id,
        spec: EdgeSpec(condition: .onSuccess, cycleGuard: CycleGuard(maxIterations: 5))))

    await store.handle(.nodeCheckApproved(nodes[0].id))
    await store.handle(.nodeCheckRejected(nodes[1].id))

    let closing = await store.graph.edges.first { $0.from == nodes[1].id }
    #expect(closing?.fireCount == 0)
    #expect(await store.graph.nodes[id: nodes[0].id]?.state == .succeeded)
  }

  @Test
  func guardBoundsAreCheckedNotAssumed() {
    #expect(!CycleGuard().isBounded)
    #expect(!CycleGuard(maxIterations: 0).isBounded)
    #expect(!CycleGuard(until: "   ").isBounded)
    #expect(CycleGuard(maxIterations: 1).isBounded)
    #expect(CycleGuard(until: "test -f done").isBounded)
  }

  @Test
  func aLegacyEdgesFiredBooleanBecomesAFireCount() throws {
    // Every graph on disk predates `fireCount`; a mis-migration here would re-fire
    // edges that had already run.
    let json = """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "from": "00000000-0000-0000-0000-000000000002",
        "to": "00000000-0000-0000-0000-000000000003",
        "kind": "handoff",
        "condition": "always",
        "fired": true
      }
      """
    let edge = try JSONDecoder().decode(LoopEdge.self, from: Data(json.utf8))

    #expect(edge.fireCount == 1)
    #expect(edge.fired)
    // No guard, already fired — so it must not be eligible to fire again.
    #expect(!edge.mayFireAgain)
  }
}
