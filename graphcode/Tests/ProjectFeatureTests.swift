import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

/// `ProjectFeature` no longer owns selection (which node's terminal, if any, is
/// showing) as of the multi-project sidebar follow-up to Phase 4
/// (docs/07-roadmap.md#phase-4--projects) — that's inherently cross-project now that
/// several projects can share one sidebar and detail pane, so it moved to
/// `AppFeature` (see `AppFeatureTests`). What's left here is genuinely this feature's
/// own job: reacting to a synced `DaemonEvent` and assigning canvas positions.
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
}
