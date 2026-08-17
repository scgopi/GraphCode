import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// One loop's terminal workspace — header, this loop's own tab bar (not shared with
/// other loops), and the selected tab's pane(s). Replaces Phase 4's
/// `LoopNodeDetailView`. There's no manual approve/reject bar: a loop resolves itself
/// the moment its Claude Code session exits (see `LoopWorkspaceFeature.primarySurfaceExited`).
struct LoopWorkspaceView: View {
  @Bindable var store: StoreOf<LoopWorkspaceFeature>

  /// What the loop bar's elapsed label is measured against — the window's one 30s tick,
  /// the same one the canvases' cards use. See `CanvasClock`.
  @State private var now = Date()
  var body: some View {
    HStack(spacing: 0) {
      workspace
      // Never drawn empty, whatever the toggle says — see `LoopWorkspaceRail.hasContent`.
      if store.isRailVisible && railHasContent {
        LoopWorkspaceRail(
          node: store.node, graph: store.graph, now: now,
          width: railWidth,
          isSummaryFolded: store.isSummaryFolded,
          seenBeatID: store.seenBeatID,
          onSummaryFoldToggled: { store.send(.summaryFoldToggled) },
          onSummaryAnswerTapped: { store.send(.summaryAnswerTapped) }
        ) { targetID in
          store.send(.railTargetTapped(targetID))
        }
        .overlay(alignment: .leading) { railResizeHandle }
      } else if LoopSummaryPresentation.hasContent(node: store.node) {
        // Hidden is not gone: 26 points keeps the loop's state dot and the word, and the
        // ask still gets through. See `SummaryGutter`.
        SummaryGutter(node: store.node, now: now) { store.send(.railToggled) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(CanvasClock.tick) { now = $0 }
    .onDisappear { store.send(.workspaceLeft) }
    // The folder header goes in the toolbar, not in the `VStack` above, and the pane
    // does *not* claim the titlebar inset. Both were tried: `.ignoresSafeArea(.top)`
    // does slide content up into the band, but whatever lands there is drawn under the
    // window's titlebar layer and is simply never seen — a plain red rectangle put
    // there is as invisible as this header was. A toolbar item is the supported way
    // into that band, and it puts the folder name level with the window controls while
    // the tab strip keeps the row below to itself.
    .toolbar { folderToolbar }
  }

  /// The rail's width mid-drag, before it is committed to the reducer on release.
  @State private var dragWidth: CGFloat?

  /// Whether the resize cursor is currently pushed — see `railResizeHandle`.
  @State private var isOverRailEdge = false

  private var railWidth: CGFloat { dragWidth ?? store.railWidth }

  /// The rail's leading edge, as a grab handle.
  ///
  /// Six points of transparent hit area over the hairline the rail already draws, rather
  /// than a visible splitter: the seam is the affordance, and a second line beside the
  /// first would read as a border that had been drawn twice. Dragging left widens, which
  /// is what the sign flip is for — a right-hand panel grows as the pointer moves away
  /// from its edge.
  private var railResizeHandle: some View {
    Rectangle()
      .fill(.clear)
      .frame(width: 6)
      .contentShape(Rectangle())
      // `push`/`pop` is a stack, and the pop only arrives if the pointer leaves the way it
      // came. Hiding the rail with ⌥G mid-hover, or switching to the canvas, takes the
      // handle out from under the cursor with no exit — and the resize arrows then follow
      // the pointer around the whole app until something else pushes over them.
      .onHover { inside in
        guard inside != isOverRailEdge else { return }
        isOverRailEdge = inside
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
      }
      .onDisappear {
        guard isOverRailEdge else { return }
        isOverRailEdge = false
        NSCursor.pop()
      }
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { value in
            dragWidth = LoopWorkspaceRail.clamped(store.railWidth - value.translation.width)
          }
          .onEnded { value in
            let settled = LoopWorkspaceRail.clamped(store.railWidth - value.translation.width)
            dragWidth = nil
            store.send(.railWidthChanged(settled))
          }
      )
  }

  /// Whether this loop gives the rail anything to say — see `LoopWorkspaceRail`.
  var railHasContent: Bool {
    LoopWorkspaceRail.hasContent(node: store.node, graph: store.graph)
  }

  private var railShortcut: some View {
    Button("") { store.send(.railToggled) }
      .keyboardShortcut("g", modifiers: .option)
      .frame(width: 0, height: 0)
      .opacity(0)
  }

  private var workspace: some View {
    VStack(spacing: 0) {
      // The loop itself, over its terminals — see `LoopWorkspaceLoopBar` for why a band
      // that was once removed from here is back.
      LoopWorkspaceLoopBar(
        node: store.node,
        now: now,
        onStop: { store.send(.stopLoopTapped) },
        onShowInGraph: { store.send(.showInGraphTapped) })
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
  }

  /// The folder name, at the leading edge of the titlebar band.
  ///
  /// `.navigation` rather than `.principal` so it sits left, next to the sidebar's own
  /// controls, instead of floating in the middle of the window.
  ///
  /// macOS 26 gives every toolbar item a glass capsule behind it, which around a plain
  /// icon-and-name reads as a button you can press — it isn't one. `sharedBackground
  /// Visibility(.hidden)` takes the capsule away and leaves the label; it doesn't exist
  /// before macOS 26, and the deployment target is 15, hence the branch. On 15 the item
  /// simply renders without a capsule anyway.
  @ToolbarContentBuilder
  private var folderToolbar: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .navigation) {
        ProjectHeader(
          name: store.projectName,
          isRemote: RemoteProjectLocation.parse(projectPath: store.projectPath) != nil)
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .navigation) {
        ProjectHeader(
          name: store.projectName,
          isRemote: RemoteProjectLocation.parse(projectPath: store.projectPath) != nil)
      }
    }
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
            // Only the agent tab has a loop state to report — a plain shell is a shell.
            // This is the fix for "a background tab asked a question and nothing said so".
            state: tab.surfaces.contains(where: \.launchesClaudeCode) ? store.node.state : nil,
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

  /// ⌘1…⌘9, the one set of shortcuts a static menu can't express: which tab each number
  /// selects depends on the tabs this workspace happens to have. Everything else moved
  /// to the Loop and Terminal menus, where it is visible — see `GraphcodeCommands`.
  private var workspaceKeyboardShortcuts: some View {
    ForEach(Array(store.layout.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
      hiddenShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) {
        store.send(.tabSelected(tab.id))
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
    case .sketch, .turnBased, .composite: return "Claude Code"
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

  /// One tab's panes, however many splits deep they go.
  private func paneContent(for tab: TabLayout) -> some View {
    SplitTreeView(node: tab.root) { ref in surfaceView(tab: tab, ref: ref) }
  }

  @ViewBuilder
  private func surfaceView(tab: TabLayout, ref: SurfaceRef) -> some View {
    let isFocused = ref.id == tab.focusedSurface.id
    VStack(spacing: 0) {
      // 22pt of "which pane is this and does it have the keyboard". The veil below says
      // only the second half, and two identical black rectangles said neither.
      PaneHeaderView(
        title: ref.launchesClaudeCode ? "agent" : "shell",
        isFocused: isFocused && tab.id == store.layout.selectedTabID,
        detail: ref.launchesClaudeCode ? store.node.backend.displayName.lowercased() : "zsh")
      terminal(tab: tab, ref: ref)
    }
    // `ref.id` (not just this slot's structural position) is a surface's real
    // identity — without this, collapsing a split (which reassigns `tab.primary` to
    // what used to be `tab.secondary`, see `.paneClosed`) would keep reusing the old
    // primary's `NSView`/session instead of picking up the surviving one.
    .id(ref.id)
  }

  private func terminal(tab: TabLayout, ref: SurfaceRef) -> some View {
    GhosttyTerminalView(
      // The pane's own id, which is also the key its live surface is held under while
      // some other loop is on screen — see `TerminalSurfaceStore`.
      surfaceID: ref.id,
      sessionName: ref.zmxSessionName,
      launchesClaudeCode: ref.launchesClaudeCode,
      // The loop's own backend and tier, so an attached session matches what
      // `graphcoded` would have launched detached. The tier is passed unresolved — see
      // `GhosttyTerminalView.pinnedModelTier`.
      backend: store.node.backend,
      pinnedModelTier: store.node.modelTier,
      loopType: store.node.loopType,
      // Only the agent surface of an unattended node starts from a prompt (a time-based
      // loop's `/loop`, a goal-based loop's goal); a turn-based loop's session opens
      // bare, and extra tabs/splits are plain shells either way.
      initialPrompt: ref.launchesClaudeCode ? store.node.sessionPrompt : nil,
      // A node without its own worktree yet still belongs to a project — its shells
      // should open there, not wherever the app process happened to launch from. A
      // global-graph loop belongs to no folder at all: home, the same answer the
      // daemon's `ZmxSessionLauncher.workingDirectory` gives its unattended launches.
      workingDirectory: store.node.worktreeBinding?.worktreePath
        ?? (store.projectPath.hasPrefix("graphcode://")
          ? NSHomeDirectory() : store.projectPath),
      // The graph's own project, for the session briefing — deliberately not the
      // worktree, whose path names a graph that doesn't exist. Every surface gets it,
      // not just the agent's: a remote project's plain-shell tabs open on the remote
      // host, and which host that is lives in this path.
      projectPath: store.projectPath,
      // Only *one* surface in the whole workspace is the live one: the showing tab's
      // focused pane. Every other surface stays mounted and must not hold the keyboard —
      // including the other half of this tab's own split, which is what stops both panes
      // drawing a filled cursor as though each of them had it.
      isActive: tab.id == store.layout.selectedTabID && ref.id == tab.focusedSurface.id,
      // Visible is the weaker claim, and the one libghostty renders on: this tab is
      // showing, whether or not this pane of it has the keyboard. A hidden tab's surfaces
      // are told so and stop drawing entirely — without that they render frames nobody
      // can see, at the same thread priority as the pane you're actually looking at.
      isVisible: tab.id == store.layout.selectedTabID,
      onFocusRequested: { store.send(.paneFocused(tabID: tab.id, surfaceID: ref.id)) },
      // Only the agent pane lingers after its process exits (it holds the loop's
      // resolution, so `.primarySurfaceExited` leaves it mounted) — which left the
      // "Press any key to close" screen with no key that did anything. The keypress is
      // the human agreeing the loop is over: the workspace closes and the node goes
      // with it. A plain shell's exit already closes its pane, so it has no screen to
      // acknowledge.
      onExitAcknowledged: ref.launchesClaudeCode
        ? { store.send(.primaryExitAcknowledged) } : nil
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
    // The unfocused half of a split reads as the one you aren't in. Only in a split —
    // a lone pane has nothing to be dimmer *than*, and veiling it would just make every
    // terminal look faded. `allowsHitTesting(false)` so the veil never swallows the very
    // click that would focus the pane underneath it.
    .overlay {
      if tab.isSplit && ref.id != tab.focusedSurface.id {
        Theme.unfocusedPaneVeil.allowsHitTesting(false)
      }
    }
    // The focused pane of a split carries an inset ring as well as the header's tint —
    // at a glance across a four-way split the ring is what you actually see.
    .overlay {
      if tab.isSplit && ref.id == tab.focusedSurface.id {
        Rectangle()
          .stroke(Theme.paneFocusTint.opacity(0.28), lineWidth: 1)
          .allowsHitTesting(false)
      }
    }
  }
}
