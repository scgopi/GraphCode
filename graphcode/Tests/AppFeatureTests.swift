import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

/// `AppFeature` owns cross-project selection (which node's terminal is showing, which
/// project's canvas is the fallback) and the list of open projects — both moved up from
/// `ProjectFeature` in the multi-project sidebar follow-up to Phase 4
/// (docs/07-roadmap.md#phase-4--projects), since a shared sidebar and detail pane
/// across several open projects can't have either live inside any one project's state.
@Suite
struct AppFeatureTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")
  private static let projectB = ProjectRef(path: "/tmp/project-b", name: "project-b")

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
    }
    store.exhaustivity = .off

    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(blockedNode.id))))
    #expect(store.state.detail == nil)
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
    }
    store.exhaustivity = .off

    // Time-based nodes run headlessly in graphcoded — there's no local interactive
    // session for a human to attach to (see docs/04-cli-backends.md).
    await store.send(
      .projects(.element(id: Self.projectA.path, action: .nodeTapped(timeBasedNode.id))))
    #expect(store.state.detail == nil)
  }

  @Test
  @MainActor
  func openingAnIdleTurnBasedNodePresentsItsDetail() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.selectedProjectPath = Self.projectA.path

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.projects(.element(id: Self.projectA.path, action: .nodeTapped(node.id))))
    #expect(store.state.detail?.node.id == node.id)
    #expect(store.state.selectedProjectPath == Self.projectA.path)
  }

  @Test
  @MainActor
  func tappingAProjectHeaderClearsAnOpenDetail() async {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.projects.append(ProjectFeature.State(graph: LoopGraph(project: Self.projectB)))
    state.selectedProjectPath = Self.projectA.path
    state.detail = LoopNodeDetailFeature.State(node: node)

    let store = TestStore(initialState: state) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.projectHeaderTapped(Self.projectB.path))
    #expect(store.state.detail == nil)
    #expect(store.state.selectedProjectPath == Self.projectB.path)
  }
}
