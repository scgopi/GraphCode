import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

/// `GraphCanvasFeature` no longer owns graph state or blocking/firing logic from
/// Phase 3 on — `graphcoded`'s `GraphStore` does (see `GraphStoreTests`). These tests
/// cover what's still genuinely the app's job: reacting to a synced `DaemonEvent`,
/// assigning canvas positions, and gating which nodes can be opened.
@Suite
struct GraphCanvasFeatureTests {
  @Test
  @MainActor
  func graphChangedEventAssignsPositionsToNewNodes() async {
    let store = TestStore(initialState: GraphCanvasFeature.State()) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let graph = LoopGraph(title: "My first graph", nodes: [node])

    await store.send(.daemonEvent(.graphChanged(graph)))
    #expect(store.state.graph.nodes.count == 1)
    #expect(store.state.nodePositions[node.id] != nil)
  }

  @Test
  @MainActor
  func blockedNodeCannotBeOpened() async {
    var blockedNode = LoopNode(title: "Implement", checkDescription: "Correct?")
    blockedNode.state = .blocked
    var initialState = GraphCanvasFeature.State()
    initialState.graph.nodes.append(blockedNode)

    let store = TestStore(initialState: initialState) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    await store.send(.nodeTapped(blockedNode.id))
    #expect(store.state.detail == nil)
  }

  @Test
  @MainActor
  func timeBasedNodeCannotBeOpened() async {
    let timeBasedNode = LoopNode(
      title: "Poll inbox", loopType: .timeBased, triggerIntervalSeconds: 3600,
      triggerPrompt: "Check for new reports")
    var initialState = GraphCanvasFeature.State()
    initialState.graph.nodes.append(timeBasedNode)

    let store = TestStore(initialState: initialState) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    // Time-based nodes run headlessly in graphcoded — there's no local interactive
    // session for a human to attach to (see docs/04-cli-backends.md).
    await store.send(.nodeTapped(timeBasedNode.id))
    #expect(store.state.detail == nil)
  }

  @Test
  @MainActor
  func openingAnIdleTurnBasedNodePresentsItsDetail() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var initialState = GraphCanvasFeature.State()
    initialState.graph.nodes.append(node)

    let store = TestStore(initialState: initialState) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    await store.send(.nodeTapped(node.id))
    #expect(store.state.detail?.node.id == node.id)
  }
}
