import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Deletion is the half of graph editing that has to undo state, not just add it: an
/// edge that vanishes can unblock its target, and a node that vanishes takes its edges
/// and its detached session with it. Split out of `GraphStoreTests` to keep either
/// suite readable.
@Suite
struct GraphStoreDeletionTests {
  @Test
  func deletingANodeRemovesEveryEdgeTouchingIt() async {
    // A → B → C. Deleting B must take both edges with it: an edge to a node that no
    // longer exists draws as a line to nowhere and keeps its target blocked forever.
    let store = GraphStore()
    for title in ["A", "B", "C"] {
      await store.handle(
        .createNode(NodeDraft(title: title, loopType: .turnBased, checkDescription: "?")))
    }
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(.createEdge(from: nodes[1].id, to: nodes[2].id, spec: EdgeSpec()))

    await store.handle(.deleteNode(nodes[1].id))

    let graph = await store.graph
    #expect(graph.nodes.count == 2)
    #expect(graph.edges.isEmpty)
  }

  @Test
  func deletingANodeUnblocksWhateverWasWaitingOnIt() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "Implement", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    #expect(await store.graph.nodes[id: nodes[1].id]?.state == .blocked)

    await store.handle(.deleteNode(nodes[0].id))

    // Nothing can ever hand off to it now, so leaving it blocked would strand it.
    #expect(await store.graph.nodes[id: nodes[1].id]?.state == .idle)
  }

  @Test
  func aNodeStillBlockedByASecondEdgeStaysBlocked() async {
    // Two upstreams, one deleted — the survivor must keep the target blocked.
    let store = GraphStore()
    for title in ["A", "B", "Target"] {
      await store.handle(
        .createNode(NodeDraft(title: title, loopType: .turnBased, checkDescription: "?")))
    }
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[2].id, spec: EdgeSpec()))
    await store.handle(.createEdge(from: nodes[1].id, to: nodes[2].id, spec: EdgeSpec()))

    await store.handle(.deleteNode(nodes[0].id))

    let graph = await store.graph
    #expect(graph.edges.count == 1)
    #expect(graph.nodes[id: nodes[2].id]?.state == .blocked)
  }

  @Test
  func deletingANodeEndsItsSession() async {
    let killed = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onTerminateSession: { node, _ in killed.withValue { $0.append(node) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Poll inbox", loopType: .timeBased, triggerPrompt: "/loop 1h Check")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.deleteNode(nodeID))

    #expect(killed.value.map(\.id) == [nodeID])
  }

  @Test
  func deletingAnEdgeUnblocksItsTarget() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    let edgeID = await store.graph.edges[0].id

    await store.handle(.deleteEdge(edgeID))

    let graph = await store.graph
    #expect(graph.edges.isEmpty)
    #expect(graph.nodes.count == 2)
    #expect(graph.nodes[id: nodes[1].id]?.state == .idle)
  }

  @Test
  func deletingAnEdgeLeavesAnAlreadyResolvedTargetAlone() async {
    // `unblockIfStillIdle` must not resurrect a node that already succeeded — removing
    // an inbound edge is not a reason to un-resolve finished work.
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))
    await store.handle(
      .createNode(NodeDraft(title: "B", loopType: .turnBased, checkDescription: "?")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(.nodeCheckApproved(nodes[0].id))
    await store.handle(.nodeCheckApproved(nodes[1].id))
    let edgeID = await store.graph.edges[0].id

    await store.handle(.deleteEdge(edgeID))

    #expect(await store.graph.nodes[id: nodes[1].id]?.state == .succeeded)
  }

  @Test
  func deletingSomethingThatIsGoneIsANoOpNotACrash() async {
    let store = GraphStore()
    await store.handle(
      .createNode(NodeDraft(title: "A", loopType: .turnBased, checkDescription: "?")))

    await store.handle(.deleteNode(UUID()))
    await store.handle(.deleteEdge(UUID()))

    #expect(await store.graph.nodes.count == 1)
  }
}
