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
      folderHeader
      // No divider under the strip: its own shadow line is that edge now, and stacking a
      // system `Divider` on top of it draws the seam twice.
      tabBar
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
    // Up into the titlebar band. With `.windowStyle(.hiddenTitleBar)` the window has no
    // titlebar left to draw, but SwiftUI still insets the detail pane below where one
    // would have been — which left the tab strip sitting under an empty row. Claiming
    // that inset puts the tabs at the very top of the window, level with the traffic
    // lights, the way a terminal app's tab strip sits.
    .ignoresSafeArea(.container, edges: .top)
  }

  /// Which project's terminal this is. Sized to the window-control row it shares — the
  /// workspace draws into the titlebar band (see `body`), so this sits level with the
  /// traffic lights rather than adding a band of its own.
  private var folderHeader: some View {
    HStack {
      ProjectHeader(name: store.projectName)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(height: 30)
  }

  /// The tab strip is the workspace's only chrome. There used to be a header row above
  /// it carrying the loop's title and a state badge, and neither survived: the title is
  /// already the selected row in the sidebar, and the state is already the colored dot
  /// beside it. On a screen whose entire job is showing terminals, a full-width strip
  /// repeating what the sidebar says was the most expensive thing on it.
  private var tabBar: some View {
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        ForEach(Array(store.layout.tabs.enumerated()), id: \.element.id) { index, tab in
          TabPillView(
            title: agentTabTitle(for: tab),
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
    .background(Theme.tabBarGloss)
    .overlay(alignment: .top) { Rectangle().fill(Theme.tabBarHighlight).frame(height: 1) }
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.tabBarShadowLine).frame(height: 1) }
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

  /// An unattended loop's agent tab is labelled for what it's actually doing rather than
  /// "Claude Code" — a time-based session is running its own `/loop`, a goal-based one is
  /// working toward a stop condition, and that distinction is the one thing a glance at
  /// the tab strip should tell you apart from a turn-based loop's session.
  private func agentTabTitle(for tab: TabLayout) -> String {
    guard tab.primary.launchesClaudeCode else { return "Shell" }
    switch store.node.loopType {
    case .timeBased: return "Loop"
    case .goalBased: return "Goal"
    case .turnBased, .proactive: return "Claude Code"
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
    GlossyIconButton(systemImage: systemImage, help: help, action: action)
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
      // The loop's own backend and tier, so an attached session matches what
      // `graphcoded` would have launched detached.
      backend: store.node.backend,
      modelTier: store.node.effectiveModelTier,
      // Only the agent surface of an unattended node starts from a prompt (a time-based
      // loop's `/loop`, a goal-based loop's goal); a turn-based loop's session opens
      // bare, and extra tabs/splits are plain shells either way.
      initialPrompt: ref.launchesClaudeCode ? store.node.sessionPrompt : nil,
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
    // One frame, not two. It used to cap the *content* at 220 and then stretch the pill
    // around it, which left the title and its ⌘-number floating in the middle of a wide
    // pill with dead space either side — and put the close button nowhere near the edge
    // you reach for. Stretching the content itself is what pins the trailing glyph to
    // the pill's own right edge.
    .frame(minWidth: 92, maxWidth: .infinity)
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
