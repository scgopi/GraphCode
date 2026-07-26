import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Always renders one `NavigationSplitView` — `AppSidebarView` lists every open
/// project, and the detail pane swaps between the welcome content, a project's canvas,
/// or an open loop's terminal (see `AppFeature`). Multi-project sidebar follow-up to
/// Phase 4 (docs/07-roadmap.md#phase-4--projects): before this, the whole window
/// switched between a full-window `WelcomeView` and a full-window `ProjectView` — there
/// was no sidebar at all until a project was open, and only one could be open at a time.
///
/// Every open loop's terminal (`store.openTabs`) stays mounted in the `ZStack` below for
/// as long as its tab is open, not just the active one — that's what makes switching
/// tabs instant and keeps the underlying `zmx`-backed process from reconnecting on every
/// switch, matching supacode's own terminal tab bar keeping several sessions alive at
/// once (see `LoopTabBarView`).
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationSplitView {
      AppSidebarView(store: store)
    } detail: {
      VStack(spacing: 0) {
        if !store.openTabs.isEmpty {
          LoopTabBarView(store: store)
          Divider()
        }
        detail
      }
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
  }

  @ViewBuilder
  private var detail: some View {
    ZStack {
      if store.projects.isEmpty {
        WelcomeView(store: store.scope(state: \.welcome, action: \.welcome))
      } else if store.activeTabID == nil {
        canvasOrPlaceholder
      }

      ForEach(store.openTabs) { tab in
        if let tabStore = tabStore(tab.id) {
          LoopNodeDetailView(store: tabStore)
            .opacity(tab.id == store.activeTabID ? 1 : 0)
            .allowsHitTesting(tab.id == store.activeTabID)
        }
      }
    }
  }

  @ViewBuilder
  private var canvasOrPlaceholder: some View {
    if let path = store.selectedProjectPath, let projectStore = selectedProjectStore(path) {
      ProjectCanvasView(store: projectStore)
    } else {
      ContentUnavailableView(
        "Select a folder", systemImage: "point.3.connected.trianglepath.dotted")
    }
  }

  private func selectedProjectStore(_ path: String) -> StoreOf<ProjectFeature>? {
    store.scope(state: \.projects[id: path], action: \.projects[id: path])
  }

  private func tabStore(_ id: UUID) -> StoreOf<LoopNodeDetailFeature>? {
    store.scope(state: \.openTabs[id: id], action: \.openTabs[id: id])
  }
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
