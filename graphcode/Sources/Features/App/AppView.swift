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
    .task { await store.send(.task).finish() }
  }
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
