import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// One loop's terminal workspace — header, this loop's own tab bar (not shared with
/// other loops), and the selected tab's pane(s). Replaces Phase 4's
/// `LoopNodeDetailView`. There's no manual approve/reject bar: a loop resolves itself
/// the moment its Claude Code session exits (see `LoopWorkspaceFeature.primarySurfaceExited`).
struct LoopWorkspaceView: View {
  @Bindable var store: StoreOf<LoopWorkspaceFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      tabBar
      Divider()
      // Every tab's surface(s) stay mounted, all the time — only the selected tab's
      // is visible/hittable. Rendering just the selected tab (as this used to) tears
      // the terminal down and rebuilds it on every switch: `GhosttyTerminalView`
      // doesn't (and can't cheaply) reconnect a live surface to a new session in
      // `updateNSView`, so the *view* only ever reflects whichever tab happened to
      // create it first — switching tabs looked like nothing happened. Keeping every
      // tab's `NSView` alive underneath means switching is instant and shows exactly
      // what that tab's shell was doing, not a fresh reattach.
      ZStack {
        ForEach(store.layout.tabs) { tab in
          let isSelected = tab.id == store.layout.selectedTabID
          paneContent(for: tab)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(isSelected)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var header: some View {
    HStack {
      Text(store.node.title).font(.headline)
      Spacer()
      PresenceBadge(state: store.node.state)
    }
    .padding(8)
  }

  private var tabBar: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        ForEach(Array(store.layout.tabs.enumerated()), id: \.element.id) { index, tab in
          TabPillView(
            title: tab.primary.launchesClaudeCode ? "Claude Code" : "Shell",
            isSelected: tab.id == store.layout.selectedTabID,
            shortcutHint: index < 9 ? "⌘\(index + 1)" : nil,
            canClose: store.layout.tabs.count > 1,
            onSelect: { store.send(.tabSelected(tab.id)) },
            onClose: { store.send(.tabClosed(tab.id)) }
          )
        }
      }
      Spacer(minLength: 8)
      HStack(spacing: 2) {
        tabBarIconButton("rectangle.split.2x1", help: "Split right") {
          store.send(.splitButtonTapped(direction: .horizontal))
        }
        tabBarIconButton("rectangle.split.1x2", help: "Split down") {
          store.send(.splitButtonTapped(direction: .vertical))
        }
        tabBarIconButton("plus", help: "New tab (plain shell)") {
          store.send(.newTabButtonTapped)
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Theme.tabBarBackground)
    .background(workspaceKeyboardShortcuts)
  }

  /// Invisible, zero-size buttons that are the only thing actually making these
  /// shortcuts work — the ⌘-number hint in each `TabPillView` is otherwise
  /// decorative. Modeled on supacode's terminal shortcuts (⌘D/⌘⇧D split, ⌘W close,
  /// ⌘←/→ switch tabs) adapted to this workspace's own action set, not its code.
  private var workspaceKeyboardShortcuts: some View {
    Group {
      ForEach(Array(store.layout.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
        hiddenShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) {
          store.send(.tabSelected(tab.id))
        }
      }
      hiddenShortcut(.rightArrow, modifiers: .command) { store.send(.selectNextTab) }
      hiddenShortcut(.leftArrow, modifiers: .command) { store.send(.selectPreviousTab) }
      hiddenShortcut("t", modifiers: .command) { store.send(.newTabButtonTapped) }
      hiddenShortcut("w", modifiers: .command) {
        store.send(.tabClosed(store.layout.selectedTabID))
      }
      hiddenShortcut("d", modifiers: .command) {
        store.send(.splitButtonTapped(direction: .horizontal))
      }
      hiddenShortcut("d", modifiers: [.command, .shift]) {
        store.send(.splitButtonTapped(direction: .vertical))
      }
    }
  }

  private func hiddenShortcut(
    _ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void
  ) -> some View {
    Button("", action: action)
      .keyboardShortcut(key, modifiers: modifiers)
      .frame(width: 0, height: 0)
      .opacity(0)
  }

  private func tabBarIconButton(
    _ systemImage: String, help: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  @ViewBuilder
  private func paneContent(for tab: TabLayout) -> some View {
    if let secondary = tab.secondary {
      let axis: Axis.Set = tab.splitDirection == .horizontal ? .horizontal : .vertical
      splitStack(axis: axis) {
        surfaceView(tab: tab, ref: tab.primary)
        Divider()
        surfaceView(tab: tab, ref: secondary)
      }
    } else {
      surfaceView(tab: tab, ref: tab.primary)
    }
  }

  @ViewBuilder
  private func splitStack<Content: View>(
    axis: Axis.Set, @ViewBuilder content: () -> Content
  ) -> some View {
    if axis == .horizontal {
      HStack(spacing: 0) { content() }
    } else {
      VStack(spacing: 0) { content() }
    }
  }

  private func surfaceView(tab: TabLayout, ref: SurfaceRef) -> some View {
    GhosttyTerminalView(
      sessionName: ref.zmxSessionName,
      launchesClaudeCode: ref.launchesClaudeCode,
      // A node without its own worktree yet still belongs to a project — its shells
      // should open there, not wherever the app process happened to launch from.
      workingDirectory: store.node.worktreeBinding?.worktreePath ?? store.projectPath
    ) { succeeded in
      if ref.launchesClaudeCode {
        store.send(.primarySurfaceExited(succeeded: succeeded))
      } else {
        // A plain shell has no success/failure of its own to report — whatever the
        // process did, the pane's job is done once it exits (including the "process
        // exited, press any key" screen: closing on ANY exit means that keypress
        // reaches here and actually dismisses it, instead of only firing when the
        // surface was force-closed mid-run).
        store.send(.paneClosed(tabID: tab.id, surfaceID: ref.id))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // `ref.id` (not just this slot's structural position) is a surface's real
    // identity — without this, collapsing a split (which reassigns `tab.primary` to
    // what used to be `tab.secondary`, see `.paneClosed`) would keep reusing the old
    // primary's `NSView`/session instead of picking up the surviving one.
    .id(ref.id)
  }
}

private struct PresenceBadge: View {
  let state: LoopState

  var body: some View {
    Text(label)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(state.presenceColor.opacity(0.2))
      .foregroundStyle(state.presenceColor)
      .clipShape(Capsule())
  }

  private var label: String {
    switch state {
    case .idle: "Idle"
    case .running: "Running"
    case .awaitingInput: "Awaiting Input"
    case .blocked: "Blocked"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .stalled: "Stalled"
    }
  }
}

/// One tab pill — fills the space its siblings leave it (matching a terminal app's
/// tab strip, not a browser's hug-the-title one), shows its ⌘-number by default and
/// swaps that for a close button on hover, and only the selected pill gets a lighter
/// fill so the strip reads as chrome with exactly one thing "showing" on it.
private struct TabPillView: View {
  let title: String
  let isSelected: Bool
  let shortcutHint: String?
  let canClose: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .lineLimit(1)
      Spacer(minLength: 4)
      trailingGlyph
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .frame(minWidth: 92, maxWidth: 220)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Theme.tabSelectedBackground : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .onHover { isHovering = $0 }
  }

  @ViewBuilder
  private var trailingGlyph: some View {
    if canClose && isHovering {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    } else if let shortcutHint {
      Text(shortcutHint)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
  }
}
