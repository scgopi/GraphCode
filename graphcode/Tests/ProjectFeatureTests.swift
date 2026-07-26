import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

/// `ProjectFeature` (renamed from `GraphCanvasFeature` in Phase 4, docs/07-roadmap.md
/// #phase-4--projects) no longer owns graph state or blocking/firing logic —
/// `graphcoded`'s `GraphStore` does (see `GraphStoreTests`). These tests cover what's
/// still genuinely the app's job: reacting to a synced `DaemonEvent`, assigning canvas
/// positions, and gating which nodes can be opened.
@Suite
struct ProjectFeatureTests {
  private static let testProject = ProjectRef(path: "/tmp/test-project", name: "test-project")

  @Test
  @MainActor
  func graphChangedEventAssignsPositionsToNewNodes() async {
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    }
    store.exhaustivity = .off

    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let graph = LoopGraph(project: Self.testProject, nodes: [node])

    await store.send(.daemonEvent(.graphChanged(graph)))
    #expect(store.state.graph.nodes.count == 1)
    #expect(store.state.nodePositions[node.id] != nil)
  }

  @Test
  @MainActor
  func blockedNodeCannotBeOpened() async {
    var blockedNode = LoopNode(title: "Implement", checkDescription: "Correct?")
    blockedNode.state = .blocked
    var initialState = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    initialState.graph.nodes.append(blockedNode)

    let store = TestStore(initialState: initialState) {
      ProjectFeature()
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
    var initialState = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    initialState.graph.nodes.append(timeBasedNode)

    let store = TestStore(initialState: initialState) {
      ProjectFeature()
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
    var initialState = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    initialState.graph.nodes.append(node)

    let store = TestStore(initialState: initialState) {
      ProjectFeature()
    }
    store.exhaustivity = .off

    await store.send(.nodeTapped(node.id))
    #expect(store.state.detail?.node.id == node.id)
  }
}
