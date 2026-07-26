import ComposableArchitecture
import SwiftUI

/// Switches between `WelcomeView` (no project open) and `ProjectView` (one open
/// project) — see `AppFeature`. Phase 4's replacement for `GraphcodeApp.swift` handing
/// its store straight to `GraphCanvasView`.
struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    Group {
      if let projectStore = store.scope(state: \.project, action: \.project) {
        ProjectView(store: projectStore)
      } else {
        WelcomeView(store: store.scope(state: \.welcome, action: \.welcome))
      }
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
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
