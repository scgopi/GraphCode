import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The Quick Chats section of the root feature — the sidebar rows, the canvas
/// (`QuickChatsCanvasView`), and the rename/delete prompts `AppView` hosts for both.
///
/// Split out of `AppFeature` rather than nested in its switch because chats share none of
/// that reducer's subject matter: no project, no graph, no daemon. What they *do* share is
/// state — a chat's workspace is the same `openLoop` a loop's is, and closing one falls
/// back to the same `detailSelection` — so this stays a slice of the root reducer over the
/// same `State` and `Action` instead of becoming a feature with a store of its own.
extension AppFeature {
  var quickChatsReducer: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .newQuickChatTapped:
        let chat = QuickChat(
          title: "Chat — \(Date().formatted(.dateTime.month(.abbreviated).day()))",
          backend: GraphcodeSettingsStore.load().defaultBackend)
        state.quickChats.append(chat)
        quickChatStore.save(Array(state.quickChats))
        openQuickChat(chat, &state)
        recordVisit(.quickChat(id: chat.id), &state)
        return .none

      case .quickChatsTapped:
        state.detailSelection = .quickChats
        state.openLoop = nil
        return .none

      case .quickChatTapped(let id):
        guard let chat = state.quickChats[id: id] else { return .none }
        guard state.openLoop?.node.id != id else { return .none }
        openQuickChat(chat, &state)
        recordVisit(.quickChat(id: id), &state)
        return .none

      case .quickChatRenameRequested(let id):
        guard let chat = state.quickChats[id: id] else { return .none }
        state.chatPendingRename = id
        // The field opens on the title it has: a rename is an edit, not a re-entry.
        state.draftChatTitle = chat.title
        return .none

      case .quickChatRenameTitleChanged(let title):
        state.draftChatTitle = title
        return .none

      case .quickChatRenameCancelled:
        state.chatPendingRename = nil
        return .none

      case .quickChatRenameConfirmed:
        let trimmed = state.draftChatTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = state.chatPendingRename else { return .none }
        state.chatPendingRename = nil
        guard !trimmed.isEmpty, state.quickChats[id: id] != nil else { return .none }
        state.quickChats[id: id]?.title = trimmed
        quickChatStore.save(Array(state.quickChats))
        // The open workspace carries a synthetic copy of this chat, so its header would
        // otherwise keep the old name until the chat was reopened.
        if state.openLoop?.node.id == id {
          state.openLoop?.node.title = trimmed
        }
        return .none

      case .quickChatDeleteRequested(let id):
        guard state.quickChats[id: id] != nil else { return .none }
        state.chatPendingDeletion = id
        return .none

      case .quickChatDeleteCancelled:
        state.chatPendingDeletion = nil
        return .none

      case .quickChatDeleteConfirmed:
        guard let id = state.chatPendingDeletion else { return .none }
        state.chatPendingDeletion = nil
        guard state.quickChats[id: id] != nil else { return .none }
        state.quickChats.remove(id: id)
        quickChatStore.save(Array(state.quickChats))
        if state.openLoop?.node.id == id {
          closeOpenWorkspace(&state)
          // Back to the chats' own canvas rather than to some folder: the chat that was
          // on screen is gone, but what you were doing was chatting.
          state.detailSelection = .quickChats
        }
        // The chat's session is app-owned — no daemon cleans it up the way GraphStore
        // does for a deleted loop, so its zmx session is killed here.
        return .run { _ in await ZmxSessionLauncher.killSession(id: id) }

      default:
        return .none
      }
    }
  }

  /// Opens a chat in the same terminal workspace a loop gets, via a synthetic node.
  /// `.composite` is the one loop type whose `sessionPrompt` is nil, which is exactly
  /// what a chat wants: the backend starts bare, with nothing pre-typed into it. The
  /// node's id is the chat's, so the workspace attaches to the chat's own long-lived
  /// zmx session, scrollback and all. Home as the working directory — a chat belongs
  /// to no project on purpose.
  func openQuickChat(_ chat: QuickChat, _ state: inout State) {
    let node = LoopNode(
      id: chat.id,
      title: chat.title,
      loopType: .composite,
      backend: chat.backend,
      createdAt: chat.createdAt)
    let layout = TerminalLayout.opening(
      forNode: chat.id, saved: terminalLayoutStore.load(forNode: chat.id))
    state.openLoop = LoopWorkspaceFeature.State(
      node: node,
      layout: layout,
      projectPath: NSHomeDirectory(),
      projectName: "Quick Chat")
    // Quick Chats is what this workspace came from, so it's what closing it falls back
    // to — the same rule a loop follows with its folder.
    state.detailSelection = .quickChats
  }
}
