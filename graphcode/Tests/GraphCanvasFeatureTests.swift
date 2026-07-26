import ComposableArchitecture
import Testing

@testable import graphcode

@Suite
struct GraphCanvasFeatureTests {
  @Test
  @MainActor
  func creatingANodeAddsItStandalone() async {
    var initialState = GraphCanvasFeature.State()
    initialState.draftTitle = "Research"
    initialState.draftCheck = "Is the approach sound?"

    let store = TestStore(initialState: initialState) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    await store.send(.createNodeConfirmed)

    #expect(store.state.graph.nodes.count == 1)
    #expect(store.state.graph.nodes[0].state == .idle)
  }

  @Test
  @MainActor
  func drawingAnEdgeBlocksTheTargetUntilFired() async {
    let from = LoopNode(title: "Research", checkDescription: "Sound?")
    let to = LoopNode(title: "Implement", checkDescription: "Correct?")
    var initialState = GraphCanvasFeature.State()
    initialState.graph.nodes.append(from)
    initialState.graph.nodes.append(to)

    let store = TestStore(initialState: initialState) {
      GraphCanvasFeature()
    }
    store.exhaustivity = .off

    await store.send(.edgeDrawn(from: from.id, to: to.id))
    #expect(store.state.graph.edges.count == 1)
    #expect(store.state.graph.nodes[id: to.id]?.state == .blocked)

    // A blocked node can't be opened.
    await store.send(.nodeTapped(to.id))
    #expect(store.state.detail == nil)

    guard let edgeID = store.state.graph.edges.first?.id else {
      Issue.record("expected an edge")
      return
    }
    await store.send(.edgeFireTapped(edgeID))
    #expect(store.state.graph.edges[id: edgeID]?.fired == true)
    #expect(store.state.graph.nodes[id: to.id]?.state == .idle)
  }

  @Test
  @MainActor
  func openingAnUnblockedNodePresentsItsDetail() async {
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
