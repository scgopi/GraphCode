import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Always renders one `NavigationSplitView` — `AppSidebarView` lists every open
/// project, and the detail pane swaps between the welcome content, the open loop's own
/// terminal workspace (tabs + splits, see `LoopWorkspaceView`), or the selected
/// project's canvas (see `AppFeature`). Multi-project sidebar follow-up to Phase 4
/// (docs/07-roadmap.md#phase-4--projects): before this, the whole window switched
/// between a full-window `WelcomeView` and a full-window `ProjectView` — there was no
/// sidebar at all until a project was open, and only one could be open at a time.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  /// What the activity strip's clock reads — the window's one 30s tick, shared with the
  /// canvases' cards. See `CanvasClock`.
  @State private var now = Date()
  /// Read once at launch, like every other `GraphcodeSettings` value the app uses: the
  /// file is the daemon's too, and re-reading it per body pass would put a disk hit on
  /// the render path.
  @State private var showsActivityStrip = GraphcodeSettingsStore.load().showsActivityStrip

  var body: some View {
    VStack(spacing: 0) {
      split
      // Full width, under the sidebar as well as the canvas: what happened happened to
      // the workspace, not to whichever pane is on screen.
      if showsActivityStrip {
        ActivityStripView(store: store, now: now)
      }
    }
    .onReceive(CanvasClock.tick) { now = $0 }
  }

  private var split: some View {
    NavigationSplitView {
      AppSidebarView(store: store)
    } detail: {
      detail
        .background(Theme.windowBackground)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // First launch only (and the sidebar's help button after that): the app's
    // vocabulary in one card, before the empty canvas has to explain itself.
    .sheet(
      isPresented: Binding(
        get: { store.showingOnboarding },
        set: { if !$0 { store.send(.onboardingDismissed) } }
      )
    ) {
      OnboardingView { store.send(.onboardingDismissed) }
    }
    // The window's own backdrop, and the glass every `Theme` scrim is layered over —
    // this is what makes the whole window translucent rather than only the sidebar.
    // A material here (rather than a color) is what lets the window sample the desktop
    // behind it; `.preferredColorScheme(.dark)` below keeps it dark whatever the
    // wallpaper is. The root `.background` that used to sit under the split view is
    // gone with it: an opaque fill behind the sidebar's own material dulled the very
    // effect the sidebar was switched to.
    .containerBackground(.ultraThinMaterial, for: .window)
    // The one strip on screen whatever pane is showing — including a full-window
    // terminal, which is where the graph is furthest away. See `StatusRollupView`.
    .toolbar {
      ToolbarItem(placement: .principal) {
        StatusRollupView(
          graphs: store.projects.map(\.graph), attention: store.attentionItems.count)
      }
      ToolbarItem(placement: .primaryAction) {
        JumpFieldButton { store.send(.jumpPaletteRequested) }
      }
      // Only when the open loop has a panel worth opening. It was shown greyed before,
      // on the argument that a visibly-unavailable control answers "where did the panel
      // go" — but a permanently dim button whose reason lives in a tooltip nobody hovers
      // is just a question mark in the toolbar, and it was read as broken rather than as
      // unavailable. ⌥G still works; the panel only matters once a loop is wired to
      // something, and that is exactly when the button comes back.
      if railHasContent {
        // A spacer, or macOS 26 fuses every trailing item into one glass capsule and the
        // toggle reads as part of the jump field rather than as its own control.
        if #available(macOS 26.0, *) {
          ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) { railToggle }
      }
    }
    // The toolbar deliberately keeps its own system material rather than being painted
    // black to match: `.toolbarBackground(_:for: .windowToolbar)` does darken the
    // titlebar band, and it was tried — a black titlebar over a black terminal loses the
    // one edge that tells you where the window starts. The system's own toolbar value is
    // the right one here.
    // The window is a fixed dark gray (`Theme`), so the appearance has to be dark too —
    // in light mode the system's near-black label colors would land on it unreadable.
    .preferredColorScheme(.dark)
    // Hosted here for the reason the rename and delete prompts are: ⌘K has to open over
    // a terminal as readily as over a canvas, and only one of those is ever on screen.
    .sheet(
      isPresented: Binding(
        get: { store.isJumpPresented },
        set: { if !$0 { store.send(.jumpPaletteDismissed) } })
    ) {
      JumpPaletteView(store: store)
    }
    .task { await store.send(.task).finish() }
    .confirmationDialog(
      // Naming the loop matters here in a way it didn't on the canvas: from the sidebar
      // you may be several projects away from the thing you right-clicked.
      "Delete “\(store.pendingLoopDeletion?.node.title ?? "")”?",
      isPresented: Binding(
        get: { store.pendingLoopDeletion != nil },
        set: { if !$0 { cancelPendingDeletion() } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) { confirmPendingDeletion() }
      Button("Cancel", role: .cancel) { cancelPendingDeletion() }
    } message: {
      Text(
        "Its terminal session is ended and every edge touching it is removed. "
          + "This can't be undone.")
    }
    // A loop's title is written before the work exists, so it's the one thing about a
    // loop people want to change afterwards. An alert with a field rather than a sheet:
    // there is exactly one thing to type, and it has to be able to open over a terminal
    // as readily as over a canvas.
    .alert(
      "Rename “\(store.pendingLoopRename?.node.title ?? "")”",
      isPresented: Binding(
        get: { store.pendingLoopRename != nil },
        set: { if !$0 { cancelPendingRename() } }
      )
    ) {
      // Submitting from the keyboard goes through the same action Rename does, so
      // Return commits instead of dismissing the alert with the typing thrown away.
      TextField("Title", text: renameTitleBinding)
        .onSubmit { confirmPendingRename() }
      Button("Rename") { confirmPendingRename() }
      Button("Cancel", role: .cancel) { cancelPendingRename() }
    } message: {
      Text("Only the name changes — the loop keeps its session, its edges, and its work.")
    }
    // A chat's rename and delete are hosted here rather than by the sidebar for the
    // reason a loop's are: either can be started from the sidebar row or from the Quick
    // Chats canvas, and only one of those two is ever the surface on screen.
    .alert(
      "Rename Chat",
      isPresented: Binding(
        get: { store.pendingChatRename != nil },
        set: { if !$0 { store.send(.quickChatRenameCancelled) } }
      )
    ) {
      TextField("Title", text: chatTitleBinding)
        .onSubmit { store.send(.quickChatRenameConfirmed) }
      Button("Rename") { store.send(.quickChatRenameConfirmed) }
      Button("Cancel", role: .cancel) { store.send(.quickChatRenameCancelled) }
    }
    .confirmationDialog(
      "Delete this chat?",
      isPresented: Binding(
        get: { store.pendingChatDeletion != nil },
        set: { if !$0 { store.send(.quickChatDeleteCancelled) } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Chat", role: .destructive) { store.send(.quickChatDeleteConfirmed) }
      Button("Cancel", role: .cancel) { store.send(.quickChatDeleteCancelled) }
    } message: {
      Text(
        "\(store.pendingChatDeletion?.title ?? "This chat")'s session and scrollback "
          + "will be permanently deleted.")
    }
  }

  /// The open loop's trailing panel, toggled from where macOS puts an inspector toggle.
  ///
  /// The tint follows what is actually on screen rather than the stored preference. It
  /// used to follow the preference, so a loop with nothing to show rendered the button
  /// bright accent-blue *and* disabled — it looked switched on and did nothing when
  /// clicked, which is the worst of both.
  /// Whether the open loop has a panel worth a button.
  private var railHasContent: Bool {
    guard let open = store.openLoop else { return false }
    return LoopWorkspaceRail.hasContent(node: open.node, graph: open.graph)
  }

  @ViewBuilder
  private var railToggle: some View {
    let showing = store.openLoop?.isRailVisible ?? false
    Button {
      store.send(.openLoop(.railToggled))
    } label: {
      Image(systemName: "sidebar.trailing")
        .foregroundStyle(showing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    }
    .help(railHelp(showing: showing))
  }

  private func railHelp(showing: Bool) -> String {
    guard let open = store.openLoop else { return "" }
    let count = LoopWorkspaceRail.downstreamCount(node: open.node, graph: open.graph)
    let what = count == 1 ? "1 hand-off" : "\(count) hand-offs"
    return showing
      ? "Hide this loop's panel (⌥G)"
      : "Show what this loop feeds — \(what) (⌥G)"
  }

  /// The chat rename field's draft, straight through to the reducer — the prompt is
  /// raised from two different surfaces, so the text it holds can't live in either.
  private var chatTitleBinding: Binding<String> {
    Binding(
      get: { store.draftChatTitle },
      set: { store.send(.quickChatRenameTitleChanged($0)) })
  }

  /// Reads and writes the pending rename's draft text straight through to the project it
  /// belongs to. Built by hand rather than with `@Bindable`: this view holds the app
  /// store, and which project's field is on screen isn't known until the prompt is up.
  private var renameTitleBinding: Binding<String> {
    Binding(
      get: { store.pendingLoopRename?.title ?? "" },
      set: { newValue in
        guard let path = store.pendingLoopRename?.projectPath else { return }
        store.send(.projects(.element(id: path, action: .renameTitleChanged(newValue))))
      })
  }

  private func confirmPendingRename() {
    guard let path = store.pendingLoopRename?.projectPath else { return }
    store.send(.projects(.element(id: path, action: .renameNodeConfirmed)))
  }

  private func cancelPendingRename() {
    guard let path = store.pendingLoopRename?.projectPath else { return }
    store.send(.projects(.element(id: path, action: .renameNodeCancelled)))
  }

  private func confirmPendingDeletion() {
    guard let path = store.pendingLoopDeletion?.projectPath else { return }
    store.send(.projects(.element(id: path, action: .deleteNodeConfirmed)))
  }

  private func cancelPendingDeletion() {
    guard let path = store.pendingLoopDeletion?.projectPath else { return }
    store.send(.projects(.element(id: path, action: .deleteNodeCancelled)))
  }

  @ViewBuilder
  private var detail: some View {
    // An open workspace comes first, and Quick Chats before the welcome fallback: both
    // are the app's own surfaces and neither needs a folder to exist, so "no projects
    // open yet" must not draw over something the human explicitly opened.
    if let workspaceStore = store.scope(state: \.openLoop, action: \.openLoop) {
      LoopWorkspaceView(store: workspaceStore)
    } else if store.detailSelection == .quickChats {
      QuickChatsCanvasView(store: store)
    } else if store.projects.isEmpty {
      WelcomeView(store: store.scope(state: \.welcome, action: \.welcome))
    } else if store.selectedProjectPath == LoopGraphScope.globalPath {
      // The Graph row's canvas is the whole workspace, not the global graph's own nodes
      // in isolation — it needs every open project's graph, which no project-scoped
      // store can see. See `GraphOverviewView`.
      GraphOverviewView(store: store)
    } else if let path = store.selectedProjectPath, let projectStore = selectedProjectStore(path) {
      ProjectCanvasView(store: projectStore)
    } else {
      ContentUnavailableView(
        "Select a folder", systemImage: "point.3.connected.trianglepath.dotted")
    }
  }

  private func selectedProjectStore(_ path: String) -> StoreOf<ProjectFeature>? {
    store.scope(state: \.projects[id: path], action: \.projects[id: path])
  }
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
