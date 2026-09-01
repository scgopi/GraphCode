import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The app's own menus.
///
/// Every one of these shortcuts already worked — they were invisible zero-size buttons
/// carrying `.keyboardShortcut`, which is the trick you reach for when there is no menu
/// to hang them on. The cost is that nothing tells anyone they exist: ⌘D splits a pane
/// and no menu in the bar says so, which makes it a shortcut for people who read the
/// source. A menu item is the discoverable half of a keyboard shortcut, and macOS draws
/// the key equivalent beside it for free.
///
/// Two menus rather than one, split by what you are acting on: **Loop** is the graph —
/// which loop you are in, what it feeds, where to go next. **Terminal** is the panes in
/// front of you. Both are disabled wholesale when no workspace is open, which is also
/// how someone learns these are workspace verbs rather than app ones.
struct GraphcodeCommands: Commands {
  let store: StoreOf<AppFeature>

  private var hasWorkspace: Bool { store.openLoop != nil }

  /// Whether the open loop has a panel to toggle — the same rule the toolbar button is
  /// gated on, so the menu can't offer something the toolbar says doesn't exist.
  private var hasRail: Bool {
    guard let open = store.openLoop else { return false }
    return LoopWorkspaceRail.hasContent(node: open.node, graph: open.graph)
  }

  var body: some Commands {
    // `File ▸ Worktrees…` — the sweeper for the focused folder, same sheet the lane
    // chip and the context menus open. In File because it is about the folder on disk,
    // not about any loop.
    CommandGroup(after: .newItem) {
      Divider()
      // Beside New Window rather than in a menu of its own: a workspace is the other
      // thing "new" can mean here, and the one that opens a window you can put on a
      // second screen.
      Menu("Workspace") {
        WorkspaceMenuItems(store: store, showsShortcuts: true)
      }
      Divider()
      Button("Worktrees…") {
        guard let path = focusedFolderPath else { return }
        store.send(.worktrees(.sweepRequested(projectPath: path)))
      }
      .disabled(focusedFolderPath == nil)
    }

    CommandMenu("Loop") {
      Button("Jump to Loop…") { store.send(.jumpPaletteRequested) }
        .keyboardShortcut("k", modifiers: .command)
      Button("Review What Needs You") { store.send(.reviewAttentionTapped) }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(store.attentionItems.isEmpty)

      Divider()

      // Where you have been, as opposed to what sits beside what — the two below walk
      // sidebar order, these walk the order loops were actually opened in.
      Button("Back") { store.send(.historyBackTapped) }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
        .disabled(!store.loopHistory.canGoBack)
      Button("Forward") { store.send(.historyForwardTapped) }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        .disabled(!store.loopHistory.canGoForward)

      Divider()

      Button("Next Loop") { store.send(.selectNextLoop) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
      Button("Previous Loop") { store.send(.selectPreviousLoop) }
        .keyboardShortcut("[", modifiers: [.command, .shift])

      Divider()

      Button(railTitle) { store.send(.openLoop(.railToggled)) }
        .keyboardShortcut("g", modifiers: .option)
        .disabled(!hasRail)
      Button("Show in Graph") { store.send(.openLoop(.showInGraphTapped)) }
        .disabled(!hasWorkspace)
      Button("Stop Loop") { store.send(.openLoop(.stopLoopTapped)) }
        .disabled(!hasWorkspace)

      Divider()

      // The recovery for a replaced `zmx` or backend CLI: the session is killed and
      // picked back up on the same transcript. See `AppFeature+LoopSessions.swift`.
      Button("Restart Session") { store.send(.sessionRestart(.openLoopTapped)) }
        .disabled(!hasRestartableLoop)
      Button("Restart All Sessions…") { store.send(.sessionRestart(.allTapped)) }
        .disabled(store.projects.isEmpty)
    }

    CommandMenu("Terminal") {
      Button("New Tab") { store.send(.openLoop(.newTabButtonTapped)) }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!hasWorkspace)
      Button("Close Tab") { store.send(.openLoop(.tabClosed(selectedTabID))) }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(!canCloseTab)

      Divider()

      // The two that prompted this: ⌘D and ⌘⇧D have split panes since the workspace
      // existed, and no menu in the bar admitted it.
      Button("Split Right") { store.send(.openLoop(.splitButtonTapped(direction: .horizontal))) }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(!hasWorkspace)
      Button("Split Down") { store.send(.openLoop(.splitButtonTapped(direction: .vertical))) }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(!hasWorkspace)

      Divider()

      Button("Next Tab") { store.send(.openLoop(.selectNextTab)) }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .disabled(!hasWorkspace)
      Button("Previous Tab") { store.send(.openLoop(.selectPreviousTab)) }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .disabled(!hasWorkspace)
      Button("Focus Next Pane") { store.send(.openLoop(.focusNextPane)) }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!isSplit)
      Button("Focus Previous Pane") { store.send(.openLoop(.focusPreviousPane)) }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(!isSplit)
    }
  }

  /// The folder `File ▸ Worktrees…` acts on: the open loop's, else the selected one —
  /// and only a local folder, since the global graph and a remote project have nothing
  /// on this disk to sweep.
  private var focusedFolderPath: String? {
    let candidate = store.openLoop?.projectPath ?? store.selectedProjectPath
    guard let candidate, AppWorktreesReducer.tracksWorktrees(candidate),
      store.projects[id: candidate] != nil
    else { return nil }
    return candidate
  }

  /// A chat is not a node in any graph, so there is nothing for the daemon to restart.
  private var hasRestartableLoop: Bool {
    guard let open = store.openLoop else { return false }
    return store.quickChats[id: open.node.id] == nil
  }

  private var railTitle: String {
    (store.openLoop?.isRailVisible ?? false) ? "Hide Loop Panel" : "Show Loop Panel"
  }

  /// A workspace always keeps at least one tab, so closing the last one is refused by
  /// the reducer — the menu says so rather than offering a no-op.
  private var canCloseTab: Bool { (store.openLoop?.layout.tabs.count ?? 0) > 1 }

  private var isSplit: Bool {
    guard let layout = store.openLoop?.layout else { return false }
    return layout.tabs[id: layout.selectedTabID]?.isSplit ?? false
  }

  /// Harmless when no workspace is open: every item that uses it is disabled.
  private var selectedTabID: UUID {
    store.openLoop?.layout.selectedTabID ?? UUID()
  }
}
