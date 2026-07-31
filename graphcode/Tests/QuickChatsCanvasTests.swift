import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Quick Chats is a project-like surface without a project: the sidebar's header row
/// opens a canvas of chat cards (`QuickChatsCanvasView`) exactly as a folder's row opens
/// that folder's graph, and an empty one says so rather than drawing a blank pane. These
/// cover the selection and the two card verbs — the canvas draws whatever
/// `detailSelection` and `quickChats` say, so that's what there is to assert on.
@Suite
struct QuickChatsCanvasTests {
  private static let project = ProjectRef(path: "/tmp/project", name: "project")

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private typealias AppTestStore = TestStore<AppFeature.State, AppFeature.Action>

  private func makeStore(_ state: AppFeature.State) -> AppTestStore {
    let directory = temporaryDirectory()
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.quickChatStore = QuickChatStore(baseDirectory: directory)
      $0.terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  @MainActor
  func tappingTheHeaderShowsTheChatsCanvasAndClosesTheOpenWorkspace() async {
    // The row is a peer of a folder's: selecting it swaps the detail pane to the chats'
    // own canvas, and — like selecting a folder — puts away whatever workspace was open.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    var state = AppFeature.State()
    state.projects.append(
      ProjectFeature.State(graph: LoopGraph(project: Self.project, nodes: [node])))
    let store = makeStore(state)

    await store.send(.projects(.element(id: Self.project.path, action: .nodeTapped(node.id))))
    #expect(store.state.openLoop != nil)

    await store.send(.quickChatsTapped)
    #expect(store.state.detailSelection == .quickChats)
    #expect(store.state.openLoop == nil)
    // Quick Chats is not a folder, so no folder is selected while it's showing.
    #expect(store.state.selectedProjectPath == nil)
  }

  @Test
  @MainActor
  func anEmptyChatListIsWhatTheCanvasEmptyStateDrawsFrom() async {
    let store = makeStore(AppFeature.State())

    await store.send(.quickChatsTapped)
    #expect(store.state.quickChats.isEmpty)
    #expect(store.state.detailSelection == .quickChats)

    // The empty state's button and the canvas's + are the same action, and a chat made
    // from either opens straight into its session — a chat exists to be talked to.
    await store.send(.newQuickChatTapped)
    #expect(store.state.quickChats.count == 1)
    #expect(store.state.openLoop?.node.id == store.state.quickChats.first?.id)
    // Closing that workspace lands back on the chats canvas, not on some folder.
    #expect(store.state.detailSelection == .quickChats)
  }

  @Test
  @MainActor
  func renamingFromEitherSurfaceGoesThroughTheOnePrompt() async {
    var state = AppFeature.State()
    let chat = QuickChat(title: "Chat")
    state.quickChats.append(chat)
    let store = makeStore(state)

    await store.send(.quickChatTapped(chat.id))
    await store.send(.quickChatRenameRequested(chat.id))
    // The field opens on the current title rather than empty — a rename is an edit.
    #expect(store.state.draftChatTitle == "Chat")

    await store.send(.quickChatRenameTitleChanged("  Scratch  "))
    await store.send(.quickChatRenameConfirmed)
    #expect(store.state.quickChats[id: chat.id]?.title == "Scratch")
    // The open workspace carries the same node, so its header has to follow the rename.
    #expect(store.state.openLoop?.node.title == "Scratch")
    #expect(store.state.chatPendingRename == nil)

    // Whitespace only is not a title; the chat keeps the one it had.
    await store.send(.quickChatRenameRequested(chat.id))
    await store.send(.quickChatRenameTitleChanged("   "))
    await store.send(.quickChatRenameConfirmed)
    #expect(store.state.quickChats[id: chat.id]?.title == "Scratch")
  }

  @Test
  @MainActor
  func deletingTheOpenChatFallsBackToTheChatsCanvas() async {
    var state = AppFeature.State()
    let chat = QuickChat(title: "Chat")
    state.quickChats.append(chat)
    state.projects.append(ProjectFeature.State(graph: LoopGraph(project: Self.project)))
    let store = makeStore(state)

    await store.send(.quickChatTapped(chat.id))
    await store.send(.quickChatDeleteRequested(chat.id))
    #expect(store.state.pendingChatDeletion?.id == chat.id)

    await store.send(.quickChatDeleteCancelled)
    #expect(store.state.quickChats.count == 1)

    await store.send(.quickChatDeleteRequested(chat.id))
    await store.send(.quickChatDeleteConfirmed)
    #expect(store.state.quickChats.isEmpty)
    #expect(store.state.openLoop == nil)
    // What you were doing was chatting, so that's where the deletion leaves you — an
    // open folder is not a better answer than the surface the chat came from.
    #expect(store.state.detailSelection == .quickChats)
  }
}
