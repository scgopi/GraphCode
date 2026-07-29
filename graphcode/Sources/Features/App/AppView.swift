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

  var body: some View {
    NavigationSplitView {
      AppSidebarView(store: store)
    } detail: {
      detail
        .background(Theme.windowBackground)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.windowBackground)
    // Paints the window itself, so the titlebar and toolbar match instead of sitting a
    // shade lighter above the content.
    .containerBackground(Theme.windowBackground, for: .window)
    // The toolbar deliberately keeps its own system material rather than being painted
    // black to match: `.toolbarBackground(_:for: .windowToolbar)` does darken the
    // titlebar band, and it was tried — a black titlebar over a black terminal loses the
    // one edge that tells you where the window starts. The system's own toolbar value is
    // the right one here.
    // The window is a fixed dark gray (`Theme`), so the appearance has to be dark too —
    // in light mode the system's near-black label colors would land on it unreadable.
    .preferredColorScheme(.dark)
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
    if store.projects.isEmpty {
      WelcomeView(store: store.scope(state: \.welcome, action: \.welcome))
    } else if let workspaceStore = store.scope(state: \.openLoop, action: \.openLoop) {
      LoopWorkspaceView(store: workspaceStore)
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
