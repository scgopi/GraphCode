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

  /// An untitled draft is created as "New Loop" immediately, then renamed to whatever
  /// the backend suggests — creation never waits on the suggestion, and the rename can
  /// find its node because the draft's id *is* the node's id.
  @Test
  @MainActor
  func aBlankTitleIsFilledInByTheBackendAfterCreation() async {
    let sent = SentGraphCommandsBox()
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { command in await sent.append(command) }
      $0.titleSuggestionClient.suggest = { backend, basis in
        #expect(backend == .claudeCode)
        #expect(basis == "Sound?")
        return "Research"
      }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped)
    await store.send(.binding(.set(\.draftCheck, "Sound?")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    let commands = await sent.commands
    let draftID = store.state.draftID
    guard case .graphCommand(_, .createNode(let draft)) = commands.first else {
      return #expect(Bool(false), "expected a createNode command, got \(commands)")
    }
    #expect(draft.id == draftID)
    #expect(draft.makeNode().title == "New Loop")
    #expect(
      commands.last
        == .graphCommand(
          projectPath: Self.testProject.path,
          command: .renameNode(draftID, title: "Research")))
  }

  /// A title the human did type is kept — no suggestion is requested at all.
  @Test
  @MainActor
  func aTypedTitleIsNeverSecondGuessed() async {
    let sent = SentGraphCommandsBox()
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { command in await sent.append(command) }
      $0.titleSuggestionClient.suggest = { _, _ in
        #expect(Bool(false), "no suggestion should be requested for a typed title")
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped)
    await store.send(.binding(.set(\.draftTitle, "Research")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    let commands = await sent.commands
    #expect(commands.count == 1)
  }
}

private actor SentGraphCommandsBox {
  var commands: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { commands.append(command) }
}
