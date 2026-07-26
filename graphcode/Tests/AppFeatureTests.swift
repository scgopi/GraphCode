import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// `AppFeature` owns cross-project selection (which loop's terminal workspace is open,
/// which project's canvas is the fallback) and the list of open projects — both moved
/// up from `ProjectFeature` in the multi-project sidebar follow-up to Phase 4
/// (docs/07-roadmap.md#phase-4--projects), since a shared sidebar and detail pane
/// across several open projects can't have either live inside any one project's state.
/// `openLoop` (at most one loop's whole terminal workspace, see
/// `LoopWorkspaceFeature`) replaced a cross-loop tab bar in the follow-up after that.
@Suite
struct AppFeatureTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")
  private static let projectB = ProjectRef(path: "/tmp/project-b", name: "project-b")

  private func makeTerminalLayoutStore() -> TerminalLayoutStore {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    return TerminalLayoutStore(baseDirectory: directory)
  }

  @Test
  @MainActor
  func openingTwoDifferentProjectsAddsBothAndAutoSelectsTheSecond() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(LoopGraph(project: Self.projectA))))
    #expect(store.state.projects.count == 1)
    #expect(store.state.selectedProjectPath == Self.projectA.path)

    await store.send(.daemonEvent(.graphChanged(LoopGraph(project: Self.projectB))))
    #expect(store.state.projects.count == 2)
    #expect(store.state.selectedProjectPath == Self.projectB.path)
  }

  @Test
  @MainActor
  func aGraphChangedForAnAlreadyOpenProjectUpdatesItInPlace() async {
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(LoopGraph(project: Self.projectA))))
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: Self.projectA, nodes: [node]))))
    // The update for an already-open project is forwarded via a `.send(.projects(...))`
    // effect rather than mutated inline — drain it before asserting.
    await store.receive(\.projects)

    #expect(store.state.projects.count == 1)
    #expect(store.state.projects[id: Self.projectA.path]?.graph.nodes.count == 1)
  }

  @Test
  @MainActor
  func blockedNodeCannotBeOpened() async {
    var blockedNode = LoopNode(title: "Implement", checkDescription: "Correct?")
    blockedNode.state = .blocked
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [blockedNode])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = makeTerminalLayoutStore()
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(blockedNode.id))))
    #expect(store.state.openLoop == nil)
  }

  @Test
  @MainActor
  func timeBasedNodeCannotBeOpened() async {
    let timeBasedNode = LoopNode(
      title: "Poll inbox", loopType: .timeBased, triggerIntervalSeconds: 3600,
      triggerPrompt: "Check for new reports")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [timeBasedNode])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = makeTerminalLayoutStore()
    }
    store.exhaustivity = .off

    // Time-based nodes run headlessly in graphcoded — there's no local interactive
    // session for a human to attach to (see docs/04-cli-backends.md).
    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(timeBasedNode.id))))
    #expect(store.state.openLoop == nil)
  }

  @Test
  @MainActor
  func openingAnIdleTurnBasedNodeOpensItsWorkspace() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalLayoutStore = makeTerminalLayoutStore()
    }
    store.exhaustivity = .off

    await store.send(.projects(.element(id: Self.projectA.path, action: .nodeTapped(node.id))))
    #expect(store.state.openLoop?.node.id == node.id)
    #expect(store.state.openLoop?.layout.tabs.count == 1)
    #expect(store.state.selectedProjectPath == Self.projectA.path)
  }

  @Test
  @MainActor
  func aGraphChangedRefreshesTheOpenWorkspacesNodeInPlace() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.projectA.path)

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    var succeededNode = node
    succeededNode.state = .succeeded
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: Self.projectA, nodes: [succeededNode]))))
    await store.receive(\.projects)

    #expect(store.state.openLoop?.node.state == .succeeded)
  }

  @Test
  @MainActor
  func tappingAProjectHeaderClosesTheOpenWorkspace() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.projects.append(ProjectFeature.State(graph: LoopGraph(project: Self.projectB)))
    state.selectedProjectPath = Self.projectA.path
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.projectA.path)

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.projectHeaderTapped(Self.projectB.path))
    #expect(store.state.openLoop == nil)
    #expect(store.state.selectedProjectPath == Self.projectB.path)
  }

  @Test
  @MainActor
  func aLoopsPrimarySurfaceExitingResolvesItOnTheDaemonWithNoHumanStepNeeded() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.selectedProjectPath = Self.projectA.path
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.projectA.path)

    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.openLoop(.primarySurfaceExited(succeeded: true)))
    #expect(
      await sentCommands.all == [
        .graphCommand(projectPath: Self.projectA.path, command: .nodeCheckApproved(node.id))
      ])
  }
}

private actor SentCommandsBox {
  private(set) var all: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { all.append(command) }
}
