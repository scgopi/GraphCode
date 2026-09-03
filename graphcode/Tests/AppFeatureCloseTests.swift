import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Closing the terminal, and what it is allowed to take with it (#254).
///
/// Separate from `AppFeatureTests` for the reason that suite documents about
/// `AppFeature` itself: it sits against swiftlint's `type_body_length` ceiling, and a
/// group of tests with a subject of its own is the natural place to spend the lines
/// somewhere else.
@Suite
struct AppFeatureCloseTests {
  private static let projectA = ProjectRef(path: "/tmp/project-a", name: "project-a")

  /// Closing the workspace's last tab is the other way a loop reaches its end — but the
  /// loop may still be running, and ⌘W (or a hover x, or a shell exiting) is not consent
  /// to throw one away. It raises the same "Delete Loop…" confirmation every other
  /// delete in the app goes through: nothing is sent to the daemon and the workspace
  /// stays put until the human answers (#254).
  @Test
  @MainActor
  func closingTheLastTabAsksBeforeDeletingTheLoop() async {
    let node = LoopNode(title: "Hello", checkDescription: "Said?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.selectedProjectPath = Self.projectA.path
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.projectA.path,
      projectName: Self.projectA.name)

    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.openLoop(.lastTabClosed))
    await store.receive(\.projects)
    #expect(store.state.pendingLoopDeletion?.node.id == node.id)
    #expect(store.state.openLoop != nil)
    #expect(await sentCommands.all.isEmpty)

    // And confirming it is the ordinary delete, on the ordinary path.
    await store.send(.projects(.element(id: Self.projectA.path, action: .deleteNodeConfirmed)))
    #expect(
      await sentCommands.all == [
        .graphCommand(projectPath: Self.projectA.path, command: .deleteNode(node.id))
      ])
  }

  /// Cancelling that dialog leaves the loop exactly as it was — still in the graph,
  /// still on screen, its terminals still attached.
  @Test
  @MainActor
  func decliningTheLastTabConfirmationKeepsTheLoop() async {
    let node = LoopNode(title: "Hello", checkDescription: "Said?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.projectA, nodes: [node])))
    state.selectedProjectPath = Self.projectA.path
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: Self.projectA.path,
      projectName: Self.projectA.name)

    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.openLoop(.lastTabClosed))
    await store.receive(\.projects)
    await store.send(.projects(.element(id: Self.projectA.path, action: .deleteNodeCancelled)))

    #expect(store.state.pendingLoopDeletion == nil)
    #expect(store.state.openLoop?.node.id == node.id)
    #expect(store.state.projects[id: Self.projectA.path]?.graph.nodes[id: node.id] != nil)
    #expect(await sentCommands.all.isEmpty)
  }

  /// A quick chat has no node to confirm the deletion of and no graph to delete it from.
  /// Closing its last tab just puts the terminal away; the chat outlives its session.
  @Test
  @MainActor
  func closingAQuickChatsLastTabOnlyClosesTheWorkspace() async {
    let chat = QuickChat(title: "Chat")
    var state = AppFeature.State()
    state.quickChats.append(chat)
    let node = LoopNode(id: chat.id, title: chat.title, loopType: .composite)
    state.openLoop = LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: "",
      projectName: chat.title)

    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.openLoop(.lastTabClosed))
    #expect(store.state.openLoop == nil)
    #expect(store.state.pendingLoopDeletion == nil)
    #expect(store.state.quickChats[id: chat.id] != nil)
    #expect(await sentCommands.all.isEmpty)
  }
}

private actor SentCommandsBox {
  private(set) var all: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { all.append(command) }
}
