import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Renaming a loop, end to end: the `.renameNode` wire command the daemon applies, and
/// the prompt the app puts it behind.
///
/// A title is written before the work exists — it's the one field about a loop that is
/// routinely wrong by the time the loop is running — so it's editable after creation
/// where nothing else about a node is yet. What these pin down is that editing it stays
/// *only* a rename: the loop keeps its id, and therefore its session, its edges, and its
/// place in the graph.
@Suite
struct LoopRenameTests {
  private static let project = ProjectRef(path: "/tmp/test-project", name: "test-project")

  // MARK: - The daemon's side

  @Test
  func renamingChangesTheTitleAndNothingElse() async {
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Reserch", loopType: .turnBased, checkDescription: "Sound?",
          firstInstruction: "Work")))
    let before = await store.graph.nodes[0]

    await store.handle(.renameNode(before.id, title: "Research"))

    let after = await store.graph.nodes[0]
    #expect(after.title == "Research")
    // Everything a running loop is keyed on. The id in particular *is* its `zmx` session
    // name (see `SurfaceRef`), so a rename that changed it would silently orphan the
    // terminal the human is watching.
    #expect(after.id == before.id)
    #expect(after.state == before.state)
    #expect(after.checkDescription == before.checkDescription)
    #expect(after.createdAt == before.createdAt)
  }

  @Test
  func renamingLeavesEveryEdgeInPlace() async {
    let store = GraphStore()
    for title in ["Research", "Implement"] {
      await store.handle(
        .createNode(
          NodeDraft(
            title: title, loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work")))
    }
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))

    await store.handle(.renameNode(nodes[0].id, title: "Research (v2)"))

    let graph = await store.graph
    #expect(graph.edges.count == 1)
    #expect(graph.edges[0].from == nodes[0].id)
    // Still blocked on the same upstream — a rename is not a resolution.
    #expect(graph.nodes[id: nodes[1].id]?.state == .blocked)
  }

  @Test
  func aBlankTitleIsRefusedRatherThanStored() async {
    // The same rule `NodeDraft.isValid` applies at creation. A nameless card is
    // unreachable in the sidebar and there is no undo to reach for.
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Research", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.renameNode(nodeID, title: "   "))

    #expect(await store.graph.nodes[0].title == "Research")
  }

  @Test
  func surroundingWhitespaceIsTrimmed() async {
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Research", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.renameNode(nodeID, title: "  Research  "))

    #expect(await store.graph.nodes[0].title == "Research")
  }

  @Test
  func renamingANodeThatIsGoneIsANoOp() async {
    // Reachable for real: the sidebar's menu and the daemon's graph can disagree for as
    // long as it takes a deletion to broadcast.
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Research", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))

    await store.handle(.renameNode(UUID(), title: "Something else"))

    #expect(await store.graph.nodes.count == 1)
    #expect(await store.graph.nodes[0].title == "Research")
  }

  @Test
  func aRenameIsPersistedLikeAnyOtherMutation() async {
    // `onGraphChanged` is what `ProjectRegistry` saves through; a rename that never
    // reached it would come back as the old title on the next launch.
    let saved = GraphBox()
    let store = GraphStore(onGraphChanged: { graph in Task { await saved.record(graph) } })
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Research", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.renameNode(nodeID, title: "Research (v2)"))

    // The hook is called from a detached `Task`, so wait for the value rather than for a
    // fixed interval.
    #expect(await saved.awaitTitle("Research (v2)"))
  }

  @Test
  func aLoopInsideACompositeCanBeRenamedToo() async {
    // Sub-graphs take the same vocabulary their parent graph does — that's the whole
    // point of `.subGraphCommand`, and rename is no exception.
    let store = GraphStore()
    await store.handle(.createNode(NodeDraft(title: "Nightly", loopType: .composite)))
    let compositeID = await store.graph.nodes[0].id
    await store.handle(
      .subGraphCommand(
        nodeID: compositeID,
        command: .createNode(
          NodeDraft(
            title: "Trige", loopType: .turnBased, checkDescription: "?",
            firstInstruction: "Work"))))
    let innerID = await store.graph.nodes[id: compositeID]?.subGraph?.nodes[0].id

    await store.handle(
      .subGraphCommand(
        nodeID: compositeID, command: .renameNode(innerID ?? UUID(), title: "Triage")))

    #expect(await store.graph.nodes[id: compositeID]?.subGraph?.nodes[0].title == "Triage")
  }

  // MARK: - The app's side

  @Test
  @MainActor
  func requestingARenamePrefillsTheCurrentTitleAndPresentsFromAnywhere() async {
    // Driven off `AppFeature.State`, not the canvas's own view state, so the prompt opens
    // over whatever the detail pane is showing — a terminal included, which is exactly
    // where a sidebar right-click happens.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.project.path, action: .renameNodeRequested(node.id))))

    #expect(store.state.pendingLoopRename?.node.id == node.id)
    #expect(store.state.pendingLoopRename?.projectPath == Self.project.path)
    // Prefilled: renaming is almost always amending a name, not writing a new one.
    #expect(store.state.pendingLoopRename?.title == "Research")
  }

  @Test
  @MainActor
  func confirmingSendsTheRenameToTheDaemon() async {
    let node = LoopNode(title: "Reserch", checkDescription: "Sound?")
    let sentCommands = SentCommandsBox()
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.project.path, action: .renameNodeRequested(node.id))))
    await store.send(
      .projects(.element(id: Self.project.path, action: .renameTitleChanged("Research"))))
    await store.send(.projects(.element(id: Self.project.path, action: .renameNodeConfirmed)))

    #expect(store.state.pendingLoopRename == nil)
    #expect(
      await sentCommands.all == [
        .graphCommand(
          projectPath: Self.project.path, command: .renameNode(node.id, title: "Research"))
      ])
    // The app doesn't rename anything locally — the daemon owns the graph, and the new
    // title arrives with the broadcast that follows.
    #expect(
      store.state.projects[id: Self.project.path]?.graph.nodes[id: node.id]?.title == "Reserch")
  }

  @Test
  @MainActor
  func cancellingAsksTheDaemonForNothing() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let sentCommands = SentCommandsBox()
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.project.path, action: .renameNodeRequested(node.id))))
    await store.send(
      .projects(.element(id: Self.project.path, action: .renameTitleChanged("Something else"))))
    await store.send(.projects(.element(id: Self.project.path, action: .renameNodeCancelled)))

    #expect(store.state.pendingLoopRename == nil)
    #expect(await sentCommands.all.isEmpty)
    // The abandoned draft doesn't survive to prefill the next rename.
    #expect(store.state.projects[id: Self.project.path]?.draftRenameTitle == "")
  }

  @Test
  @MainActor
  func anEmptyOrUnchangedTitleJustClosesThePrompt() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let sentCommands = SentCommandsBox()
    let store = TestStore(
      initialState: AppFeature.State(
        projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    ) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    // Cleared the field and hit Rename: that reads as "never mind", not as a command.
    await store.send(
      .projects(.element(id: Self.project.path, action: .renameNodeRequested(node.id))))
    await store.send(.projects(.element(id: Self.project.path, action: .renameTitleChanged("  "))))
    await store.send(.projects(.element(id: Self.project.path, action: .renameNodeConfirmed)))
    #expect(store.state.pendingLoopRename == nil)

    // Confirmed without typing anything — nothing to say to the daemon.
    await store.send(
      .projects(.element(id: Self.project.path, action: .renameNodeRequested(node.id))))
    await store.send(.projects(.element(id: Self.project.path, action: .renameNodeConfirmed)))

    #expect(await sentCommands.all.isEmpty)
  }

  @Test
  @MainActor
  func theOpenWorkspacePicksUpTheNewTitle() async {
    // The workspace holds its own copy of the node, so the loop being renamed while its
    // terminal is on screen has to reach it — the sidebar's menu makes that the ordinary
    // case, not an edge one.
    let node = LoopNode(title: "Reserch", checkDescription: "Sound?")
    var state = AppFeature.State(
      projects: [ProjectFeature.State(graph: Self.graph(nodes: [node]))])
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.project.path,
      projectName: Self.project.name)
    let store = TestStore(initialState: state) { AppFeature() }
    store.exhaustivity = .off

    var renamed = node
    renamed.title = "Research"
    await store.send(.daemonEvent(.graphChanged(Self.graph(nodes: [renamed]))))

    #expect(store.state.openLoop?.node.title == "Research")
  }

  private static func graph(nodes: [LoopNode]) -> LoopGraph {
    LoopGraph(project: project, nodes: IdentifiedArray(uniqueElements: nodes))
  }
}

private actor SentCommandsBox {
  private(set) var all: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { all.append(command) }
}

/// Holds whatever `GraphStore`'s persistence hook has been handed, and lets a test wait
/// for a particular title to arrive — the hook fires from a detached `Task`, so there is
/// no synchronous moment to assert against.
private actor GraphBox {
  private var graphs: [LoopGraph] = []

  func record(_ graph: LoopGraph) { graphs.append(graph) }

  func awaitTitle(_ title: String, attempts: Int = 50) async -> Bool {
    for _ in 0..<attempts {
      if graphs.contains(where: { $0.nodes.contains(where: { $0.title == title }) }) { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
}
