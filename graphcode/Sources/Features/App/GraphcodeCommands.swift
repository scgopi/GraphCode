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
    CommandMenu("Loop") {
      Button("Jump to Loop…") { store.send(.jumpPaletteRequested) }
        .keyboardShortcut("k", modifiers: .command)
      Button("Review What Needs You") { store.send(.reviewAttentionTapped) }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(store.attentionItems.isEmpty)

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
