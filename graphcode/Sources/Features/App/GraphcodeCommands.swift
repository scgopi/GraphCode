import AppKit
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
    // SwiftUI gives every `WindowGroup` a `File ▸ Close` at ⌘W, and AppKit resolves a
    // key equivalent by walking the menu bar left to right: File would answer ⌘W before
    // the Terminal menu ever saw it, so Close Pane below would never fire. Replacing the
    // group is what frees the key. Closing the window keeps a shortcut, ⇧⌘W — Ghostty's
    // own, and the pairing anyone who has closed a split before already has in their
    // hands.
    CommandGroup(replacing: .saveItem) {
      Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
        .keyboardShortcut("w", modifiers: [.command, .shift])
    }

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
      // ⌘W closes what the keyboard is in: the focused pane of a split, and the pane
      // that *is* the tab when it isn't split — Ghostty's own `close_split` binding,
      // which is the terminal these panes are. Through the reducer, closing the
      // workspace's last one asks whether the loop should end (#254), which is why it is
      // never disabled: there is always something ⌘W can close while a workspace is
      // open. "Close Pane" rather than a title that follows the split — a label that
      // renames itself to "Close Tab" collides with the item below it, and a menu with
      // the same words twice teaches nobody which key does what.
      Button("Close Pane") {
        guard let layout = store.openLoop?.layout, let focused = layout.focusedSurface
        else { return }
        store.send(.openLoop(.paneClosed(tabID: layout.selectedTabID, surfaceID: focused.id)))
      }
      .keyboardShortcut("w", modifiers: .command)
      .disabled(!hasWorkspace)
      // Every pane of the tab at once. Unbound on purpose: ⌘W already closes a tab that
      // isn't split, which is nearly every tab here, and the shortcut this used to carry
      // is spent on Close Window below — the one ⌘W has to give back.
      Button("Close Tab") { store.send(.openLoop(.tabClosed(selectedTabID))) }
        .disabled(!hasWorkspace)

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

  private var isSplit: Bool {
    guard let layout = store.openLoop?.layout else { return false }
    return layout.tabs[id: layout.selectedTabID]?.isSplit ?? false
  }

  /// Harmless when no workspace is open: every item that uses it is disabled.
  private var selectedTabID: UUID {
    store.openLoop?.layout.selectedTabID ?? UUID()
  }
}
