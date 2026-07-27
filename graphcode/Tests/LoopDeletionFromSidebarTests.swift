import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

/// Deleting a loop from the sidebar's right-click menu.
///
/// The sidebar lists every loop across every open project, so it's where people reach for
/// a loop — but its rows had no context menu at all, and the delete confirmation was
/// hosted by the canvas, which isn't rendered while a terminal is open. Both of those are
/// what these cover.
@Suite
struct LoopDeletionFromSidebarTests {
  private static let project = ProjectRef(path: "/tmp/test-project", name: "test-project")

  private static func graph(nodes: [LoopNode]) -> LoopGraph {
    LoopGraph(project: project, nodes: IdentifiedArray(uniqueElements: nodes))
  }

  @Test
  @MainActor
  func requestingDeletionSurfacesAConfirmationFromAnywhere() async {
    // The dialog is driven off `AppFeature.State`, not the canvas's own view state, so it
    // presents whatever the detail pane happens to be showing.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.project.path, action: .deleteNodeRequested(node.id))))

    #expect(store.state.pendingLoopDeletion?.node.id == node.id)
    #expect(store.state.pendingLoopDeletion?.projectPath == Self.project.path)
    #expect(store.state.pendingLoopDeletion?.node.title == "Research")
  }

  @Test
  @MainActor
  func cancellingLeavesTheLoopAlone() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.project.path, action: .deleteNodeRequested(node.id))))
    await store.send(
      .projects(.element(id: Self.project.path, action: .deleteNodeCancelled)))

    #expect(store.state.pendingLoopDeletion == nil)
    // Nothing is removed locally — the daemon owns the graph, and cancelling never asked
    // it for anything.
    #expect(store.state.projects[id: Self.project.path]?.graph.nodes.count == 1)
  }

  @Test
  @MainActor
  func nothingIsPendingWhenNoDeletionWasRequested() async {
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [
          ProjectFeature.State(graph: Self.graph(nodes: [LoopNode(title: "Research")]))
        ])
    ) {
      AppFeature()
    }

    #expect(store.state.pendingLoopDeletion == nil)
  }

  @Test
  @MainActor
  func deletingTheOpenLoopClosesItsTerminal() async {
    // The bug the sidebar menu makes easy to hit: delete the loop whose workspace is the
    // visible detail pane. Its `zmx` session has already been killed, so a terminal left
    // on screen would be showing something that no longer exists.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State(
      projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.project.path)
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    // The daemon confirms the deletion by broadcasting a graph without it.
    await store.send(.daemonEvent(.graphChanged(Self.graph(nodes: []))))

    #expect(store.state.openLoop == nil)
    // Falls back to that project's canvas rather than to nothing at all.
    #expect(store.state.selectedProjectPath == Self.project.path)
  }

  @Test
  @MainActor
  func anUnrelatedProjectsBroadcastLeavesTheOpenTerminalAlone() async {
    // The close is scoped to the open loop's own project: another project's graph says
    // nothing about whether this loop still exists, and closing on it would yank a
    // terminal out from under someone for no reason.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State(
      projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.project.path)
    // A second project that is *already* open. (A graph for a project the app has never
    // seen is a different case entirely — that's "project opened", which deliberately
    // switches away from whatever was showing.)
    let other = ProjectRef(path: "/tmp/other", name: "other")
    let otherGraph = LoopGraph(project: other, nodes: [LoopNode(title: "Elsewhere")])
    state.projects.append(ProjectFeature.State(graph: otherGraph))
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(otherGraph)))

    #expect(store.state.openLoop?.node.id == node.id)
  }

  @Test
  @MainActor
  func anOpenLoopStillInItsGraphIsKeptInSync() async {
    // The path that already worked, pinned so the new early-exit can't break it.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State(
      projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.project.path)
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    var renamed = node
    renamed.title = "Research (renamed)"
    renamed.state = .succeeded
    await store.send(.daemonEvent(.graphChanged(Self.graph(nodes: [renamed]))))

    #expect(store.state.openLoop?.node.title == "Research (renamed)")
    #expect(store.state.openLoop?.node.state == .succeeded)
  }
}
