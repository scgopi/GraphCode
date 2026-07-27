import ComposableArchitecture
import GraphcodeKit
import SwiftUI

@main
struct GraphcodeApp: App {
  static let store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  /// The app and the daemon can each start first, so both prepare the support directory.
  /// It migrates at most once and is safe to call repeatedly — see `SupportDirectory`.
  /// Doing it here rather than in `AppFeature.task` matters: `TerminalLayoutStore`'s
  /// `liveValue` resolves its directory the first time a dependency is read, which can
  /// happen before any reducer runs.
  init() {
    SupportDirectory.prepare()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
  }
}
