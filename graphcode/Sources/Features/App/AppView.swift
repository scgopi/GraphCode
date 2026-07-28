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
