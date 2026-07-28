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
    // A packaged app carries `graphcoded` and `zmx` inside it, so dragging it to
    // /Applications is the whole installation — this is what puts them in place and starts
    // the daemon. No-op for a build run from Xcode, which has no bundled helpers, so a
    // developer's own `make daemon-install` setup is left alone. Synchronous because it
    // only does real work on first launch or after an update, and the app is more useful
    // with its daemon already up than a fraction of a second earlier.
    DaemonBootstrap.installIfNeeded()
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: Self.store)
    }
    // No titlebar: it only ever said "graphcode", which the Dock, the menu bar and the
    // app icon all already say, and it cost a strip of height across the full window
    // width — real estate the canvas and the terminal workspaces both want. The toolbar
    // items survive (they move inline above the sidebar and the detail pane), and with
    // the sidebar collapsed AppKit still reserves room for the window controls rather
    // than letting them land on content.
    .windowStyle(.hiddenTitleBar)
  }
}
