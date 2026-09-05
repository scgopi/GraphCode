import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The `+` on a lane's origin dot in the Graph view: a top-level loop in that folder.
///
/// The gap it fills — a card's `+` continues a chain, and the top-right New Node lands in
/// the global graph, so starting a *new* chain in a particular folder meant crossing to
/// that folder's own canvas first.
@Suite
struct EntryLoopCreationTests {
  private func project() -> ProjectFeature.State {
    ProjectFeature.State(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/project", name: "project")))
  }

  @Test
  @MainActor
  func theEntryHandleOpensTheFormWithNoParent() async {
    // No parent means no hand-off edge: this is a beginning, not a continuation.
    let store = TestStore(initialState: project()) {
      ProjectFeature()
    } withDependencies: {
      // Opening the form lists the repository's worktrees for its branch picker.
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.addEntryLoopTapped)
    #expect(store.state.showingNewNodeForm)
    #expect(store.state.draftParentNodeID == nil)
    #expect(store.state.draftDeclaresEntry)
  }

  @Test
  @MainActor
  func aLoopMadeFromTheEntryHandleReadsAsAnEntryNotAsALooseOne() async {
    // Without the declaration a brand-new root has no edge in either direction, which is
    // `.unwired` — drawn dimmed and dashed, with two verbs offering to fix it. That is
    // the right reading for a loop someone left lying around and the wrong one for a
    // loop they just asked for.
    // The draft is seeded up front rather than typed: a `TestStore`'s state is read-only,
    // and what is under test here is what Create does with the declaration, not the form.
    var state = project()
    state.draftDeclaresEntry = true
    state.draftLoopType = .sketch
    state.draftTitle = "a beginning"
    let draftID = state.draftID

    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.createNodeConfirmed)

    #expect(store.state.declaredEntryIDs.contains(draftID))
    // Cleared, so the *next* form — the top-right New Node, a card's `+` — doesn't
    // inherit the declaration.
    #expect(!store.state.draftDeclaresEntry)
  }

  @Test
  @MainActor
  func theOrdinaryNewLoopButtonDeclaresNothing() async {
    let store = TestStore(initialState: project()) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped(parentBackend: nil))
    #expect(!store.state.draftDeclaresEntry)
  }

  @Test
  func aLaneWithNoBeginningGetsNoHandle() {
    // The handle lives where the origin dot does, and `CanvasBandView` draws that dot
    // exactly when a lane has entry ports. A `+` floating where no dot is reads as a
    // stray control — a cycle-only lane keeps the top-right New Node instead.
    let first = LoopNode(title: "first")
    let second = LoopNode(title: "second")
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/project", name: "project"))
    graph.nodes.append(first)
    graph.nodes.append(second)
    graph.edges.append(LoopEdge(from: first.id, to: second.id))
    graph.edges.append(LoopEdge(from: second.id, to: first.id))

    let overview = GraphOverview(graphs: [graph])
    #expect(overview.folders.count == 1)
    // Every loop is in the cycle, so nothing is a beginning and nothing is tethered.
    #expect(overview.folders.first?.entryPorts.isEmpty == true)
    #expect(overview.tetheredFolders.isEmpty)
  }

  @Test
  func theOverviewShowsADeclaredEntryAsAnEntry() {
    // The overview built its roles without declarations, so a loop the folder's canvas
    // called an entry still read as loose on the Graph view — the two canvases
    // disagreeing about the same loop.
    let node = LoopNode(title: "a beginning")
    var graph = LoopGraph(project: ProjectRef(path: "/tmp/project", name: "project"))
    graph.nodes.append(node)

    let loose = GraphOverview(graphs: [graph])
    #expect(loose.loops.first?.entryRole == .unwired)

    let declared = GraphOverview(
      graphs: [graph], declaredEntries: ["/tmp/project": [node.id]])
    #expect(declared.loops.first?.entryRole == .entry)
    // Either way the origin has somewhere to land — an entry port is what the lane's
    // dot draws its line to.
    #expect(declared.folders.first?.entryPorts.isEmpty == false)
  }
}
