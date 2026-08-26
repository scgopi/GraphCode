import ComposableArchitecture
import Foundation
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

    // Pinned rather than inherited: the form opens on the *remembered* type, and this
    // test's subject is the title flow, not the memory. Without the pin it read
    // whatever earlier runs left in UserDefaults.
    UserDefaults.standard.set(LoopType.goalBased.rawValue, forKey: ProjectFeature.lastLoopTypeKey)
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

  /// The budget field becomes `GoalSpec.tokenBudget` — same silent-no-op concern as the
  /// metric — and anything that isn't a positive integer travels as "no budget".
  @Test
  @MainActor
  func theBudgetFieldTravelsIntoTheGoalSpec() {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    state.draftLoopType = .goalBased
    state.draftGoal = "the sweep finishes"
    state.draftBudget = " 200000 "
    #expect(state.draft.goal?.tokenBudget == 200_000)

    for junk in ["", "0", "-5", "lots"] {
      state.draftBudget = junk
      #expect(state.draft.goal?.tokenBudget == nil, "\(junk) should mean no budget")
    }
  }

  /// The form's "Driven by" choice becomes the draft's cadence model: heartbeat mode
  /// sends the bare task plus an interval in seconds, /loop mode composes the
  /// directive exactly as it always has.
  @Test
  @MainActor
  func theCadenceChoiceTravelsIntoTheDraft() {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    state.draftLoopType = .timeBased
    state.draftTimedTask = "check for new crash reports"
    state.draftInterval = .quarterHour
    state.draftStopAfter = "20 runs"

    // Default: prompt-owned, /loop composed, stop-after included, no interval stored.
    var draft = state.draft
    #expect(draft.triggerPrompt == "/loop 15m check for new crash reports Stop after 20 runs.")
    #expect(draft.heartbeatIntervalSeconds == nil)

    // Heartbeat: bare task, interval in seconds, and the stop-after clause dropped —
    // a heartbeat loop runs until stopped, and a clause the daemon can't honour must
    // not ride into the prompt looking honoured.
    state.draftUsesHeartbeat = true
    draft = state.draft
    #expect(draft.triggerPrompt == "check for new crash reports")
    #expect(draft.heartbeatIntervalSeconds == 900)
  }

  @Test
  @MainActor
  func customIntervalsParseIntoSecondsWithAnHonestFallback() {
    #expect(ProjectFeature.State.seconds(fromInterval: "90s") == 90)
    #expect(ProjectFeature.State.seconds(fromInterval: "30m") == 1800)
    #expect(ProjectFeature.State.seconds(fromInterval: "2h") == 7200)
    #expect(ProjectFeature.State.seconds(fromInterval: "3d") == 259_200)
    // Bare digits are minutes, matching what people type into the /loop field.
    #expect(ProjectFeature.State.seconds(fromInterval: "45") == 2700)
    #expect(ProjectFeature.State.seconds(fromInterval: "tomorrow") == nil)

    var state = ProjectFeature.State(graph: LoopGraph(project: Self.testProject))
    state.draftLoopType = .timeBased
    state.draftTimedTask = "check"
    state.draftUsesHeartbeat = true
    state.draftInterval = .custom
    state.draftCustomInterval = "tomorrow"
    // A timer needs a number where an agent could have interpreted prose; the
    // fallback is the same hour a blank custom /loop interval gets.
    #expect(state.draft.heartbeatIntervalSeconds == 3600)
  }

  /// "New Child Loop…" makes a *custody* child: `createdBy` rides the draft (the
  /// daemon draws the fired-at-birth link) and no separate edge command follows — a
  /// hand-off from a long-running parent left the child blocked indefinitely while
  /// its session already ran.
  @Test
  @MainActor
  func newChildLoopCreatesACustodyChildNotAHandoff() async {
    let parent = LoopNode(
      title: "Parent", loopType: .goalBased, goal: GoalSpec(summary: "run forever"),
      state: .running)
    let sent = SentGraphCommandsBox()
    let store = TestStore(
      initialState: ProjectFeature.State(
        graph: LoopGraph(project: Self.testProject, nodes: [parent]))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.newChildLoopTapped(parent.id))
    await store.send(.binding(.set(\.draftTitle, "Child")))
    await store.send(.binding(.set(\.draftGoal, "help out")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    let commands = await sent.commands
    guard case .graphCommand(_, .createNode(let draft)) = commands.first else {
      return #expect(Bool(false), "expected a createNode command, got \(commands)")
    }
    #expect(draft.createdBy == parent.id)
    #expect(draft.backend == parent.backend)
    let edgeCommands = commands.filter {
      if case .graphCommand(_, .createEdge) = $0 { return true } else { return false }
    }
    #expect(edgeCommands.isEmpty)
  }

  /// The + handle keeps its sequencing semantic: an unfired hand-off from the parent,
  /// and no custody claim on the draft.
  @Test
  @MainActor
  func thePlusHandleStillWiresAHandoff() async {
    let parent = LoopNode(
      title: "Parent", loopType: .goalBased, goal: GoalSpec(summary: "finish soon"),
      state: .running)
    let sent = SentGraphCommandsBox()
    let store = TestStore(
      initialState: ProjectFeature.State(
        graph: LoopGraph(project: Self.testProject, nodes: [parent]))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.addChildNodeTapped(parent.id))
    await store.send(.binding(.set(\.draftTitle, "Next")))
    await store.send(.binding(.set(\.draftGoal, "take over")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    let commands = await sent.commands
    guard case .graphCommand(_, .createNode(let draft)) = commands.first else {
      return #expect(Bool(false), "expected a createNode command, got \(commands)")
    }
    #expect(draft.createdBy == nil)
    #expect(
      commands.contains {
        guard case .graphCommand(_, .createEdge(let from, let to, _)) = $0 else { return false }
        return from == parent.id && to == draft.id
      })
  }

  /// No remembered preference — a fresh machine, or a stored spelling nothing can
  /// decode — lands the form on Sketch, the type that demands nothing decided yet.
  @Test
  @MainActor
  func noRememberedPreferenceLandsOnSketch() {
    #expect(ProjectFeature.loopType(remembered: nil) == .sketch)
    #expect(ProjectFeature.loopType(remembered: "not-a-type") == .sketch)
    #expect(ProjectFeature.loopType(remembered: "goalBased") == .goalBased)
    // A remembered composite reads as Sketch: the key is app-wide, only form-creates
    // update it, and one composite must not own every project's form until the next
    // form-create. "proactive" is composite's stored spelling.
    #expect(ProjectFeature.loopType(remembered: "proactive") == .sketch)
    #expect(ProjectFeature.loopType(remembered: LoopType.composite.rawValue) == .sketch)
  }

  /// The write side of the same rule: creating a composite leaves the memory alone.
  @Test
  @MainActor
  func creatingACompositeIsNotRemembered() async {
    UserDefaults.standard.set(LoopType.goalBased.rawValue, forKey: ProjectFeature.lastLoopTypeKey)
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
    await store.send(.binding(.set(\.draftLoopType, LoopType.composite)))
    await store.send(.binding(.set(\.draftTitle, "Nightly sweep")))
    await store.send(.createNodeConfirmed)
    await store.finish()

    #expect(
      UserDefaults.standard.string(forKey: ProjectFeature.lastLoopTypeKey)
        == LoopType.goalBased.rawValue)
  }

  /// The workspace gate's live-session reading: presence is the only honest signal
  /// for "there is a terminal to attach to", and "don't know" must not open a blocked
  /// node — opening is what could start sequenced work early.
  @Test
  @MainActor
  func blockedNodesOpenExactlyWhenPresenceShowsALiveSession() {
    func node(_ presence: Presence?) -> LoopNode {
      LoopNode(
        title: "B", loopType: .timeBased, triggerPrompt: "/loop 1h x",
        presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
        state: .blocked)
    }
    #expect(node(.busy).presenceShowsLiveSession)
    #expect(node(.idle).presenceShowsLiveSession)
    #expect(node(.awaitingInput).presenceShowsLiveSession)
    #expect(!node(.absent).presenceShowsLiveSession)
    #expect(!node(.unknown).presenceShowsLiveSession)
    #expect(!node(nil).presenceShowsLiveSession)
  }
}

private actor SentGraphCommandsBox {
  var commands: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { commands.append(command) }
}
