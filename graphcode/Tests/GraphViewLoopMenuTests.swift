import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The Graph view's loop menu offers the verbs the sidebar does, and they have to work
/// from there — on a loop whose folder is not the one selected, without crossing to that
/// folder's canvas first.
///
/// That is a claim about plumbing rather than about menus: the dialogs these verbs raise
/// are hosted by `AppView` for the whole window, and the panels Export and Import run come
/// straight from the reducer. These pin the half a test can reach.
@Suite
struct GraphViewLoopMenuTests {
  private func app(withLoopIn path: String) -> (AppFeature.State, LoopNode) {
    let node = LoopNode(title: "a loop")
    var graph = LoopGraph(project: ProjectRef(path: path, name: "other"))
    graph.nodes.append(node)

    var state = AppFeature.State()
    state.projects = [
      ProjectFeature.State(
        graph: LoopGraph(project: ProjectRef(path: "/tmp/selected", name: "selected"))),
      ProjectFeature.State(graph: graph),
    ]
    // Looking at the *other* folder — the Graph view spans them all, so the loop being
    // acted on routinely belongs to one that isn't selected.
    state.detailSelection = .project("/tmp/selected")
    return (state, node)
  }

  @Test
  @MainActor
  func deletingALoopFromAnUnselectedFolderRaisesTheWindowsConfirmation() async {
    let (state, node) = app(withLoopIn: "/tmp/other")
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.projects(.element(id: "/tmp/other", action: .deleteNodeRequested(node.id))))

    // `AppView` hosts this dialog off `pendingLoopDeletion`, which scans every project —
    // so the confirmation appears without the folder being selected first.
    #expect(store.state.pendingLoopDeletion?.node.id == node.id)
    #expect(store.state.pendingLoopDeletion?.projectPath == "/tmp/other")
  }

  @Test
  @MainActor
  func renamingALoopFromAnUnselectedFolderRaisesTheWindowsPrompt() async {
    let (state, node) = app(withLoopIn: "/tmp/other")
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.projects(.element(id: "/tmp/other", action: .renameNodeRequested(node.id))))

    #expect(store.state.pendingLoopRename?.node.id == node.id)
    #expect(store.state.pendingLoopRename?.projectPath == "/tmp/other")
  }
}
