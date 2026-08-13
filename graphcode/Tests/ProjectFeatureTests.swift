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
      $0.titleSuggestionClient.suggest = { backend, basis, _ in
        #expect(backend == .claudeCode)
        #expect(basis == "Say hello")
        return "Research"
      }
    }
    store.exhaustivity = .off

    // The form opens on its default type — goal-based — and only the goal is typed.
    await store.send(.addNodeButtonTapped(parentBackend: nil))
    #expect(store.state.draftLoopType == .goalBased)
    await store.send(.binding(.set(\.draftGoal, "Say hello")))
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
      $0.titleSuggestionClient.suggest = { _, _, _ in
        #expect(Bool(false), "no suggestion should be requested for a typed title")
        return nil
      }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped(parentBackend: nil))
    await store.send(.binding(.set(\.draftTitle, "Research")))
    await store.send(.binding(.set(\.draftGoal, "Say hello")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    let commands = await sent.commands
    #expect(commands.count == 1)
  }

  /// Creating a loop from the form switches to it — but only once the daemon's
  /// broadcast delivers it, because until then there is no node to open. The switch
  /// itself is a `.nodeTapped`, which `AppFeature` turns into an open workspace.
  @Test
  @MainActor
  func aLoopCreatedFromTheFormOpensOnceItsBroadcastLands() async {
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped(parentBackend: nil))
    await store.send(.binding(.set(\.draftTitle, "Research")))
    await store.send(.binding(.set(\.draftGoal, "Say hello")))
    await store.send(.createNodeConfirmed)
    let draftID = store.state.draftID
    #expect(store.state.pendingCreatedNodeID == draftID)

    // A broadcast without the new node — some unrelated change won the race — must
    // neither open anything nor forget what is being waited for.
    let stranger = LoopNode(title: "Other", checkDescription: "Done?")
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: Self.testProject, nodes: [stranger]))))
    #expect(store.state.pendingCreatedNodeID == draftID)

    let created = LoopNode(id: draftID, title: "Research", checkDescription: "Sound?")
    await store.send(
      .daemonEvent(
        .graphChanged(LoopGraph(project: Self.testProject, nodes: [stranger, created]))))
    await store.receive(\.nodeTapped, draftID)
    #expect(store.state.pendingCreatedNodeID == nil)
    await store.finish()
  }

  /// The other half of the deal: a loop created from the CLI arrives as a bare
  /// broadcast and must not steal the screen. Exhaustive on purpose — a `.nodeTapped`
  /// emitted here would fail the test as an unreceived action.
  @Test
  @MainActor
  func aLoopArrivingFromTheCLIDoesNotSwitchToItself() async {
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    }

    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    let graph = LoopGraph(project: Self.testProject, nodes: [node])

    await store.send(.daemonEvent(.graphChanged(graph))) {
      $0.graph = graph
      // One loop, wired to nothing: the first slot of the lane — see `LaneLayout`.
      $0.nodePositions[node.id] = LaneLayout.Metrics.origin
      $0.sidebarNodeOrder = [node.id]
    }
  }

  /// A composite's **Create & open** already moves the canvas into its sub-graph —
  /// that *is* the switch, so no workspace open is queued on top of it.
  @Test
  @MainActor
  func aCompositeCreatedFromTheFormOpensItsCanvasNotAWorkspace() async {
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.addNodeButtonTapped(parentBackend: nil))
    await store.send(.binding(.set(\.draftLoopType, .composite)))
    await store.send(.binding(.set(\.draftTitle, "Nightly")))
    await store.send(.createNodeConfirmed)

    #expect(store.state.openCompositeID == store.state.draftID)
    #expect(store.state.pendingCreatedNodeID == nil)
    await store.finish()
  }

  /// The form's metric fields become the goal's `metricCommand`/`metricDirection` —
  /// a control that looks set but doesn't travel would be a silent no-op in shipping UI.
  @Test
  @MainActor
  func theMetricFieldsTravelIntoTheGoalSpec() {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    state.draftLoopType = .goalBased
    state.draftGoal = "lint is clean"
    state.draftMetric = "swiftlint lint --quiet | wc -l"
    state.draftMetricDirection = .minimize

    #expect(state.draft.goal?.metricCommand == "swiftlint lint --quiet | wc -l")
    #expect(state.draft.goal?.metricDirection == .minimize)

    // An empty field means no metric, not an empty command.
    state.draftMetric = ""
    #expect(state.draft.goal?.metricCommand == nil)
  }
}

private actor SentGraphCommandsBox {
  var commands: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { commands.append(command) }
}
