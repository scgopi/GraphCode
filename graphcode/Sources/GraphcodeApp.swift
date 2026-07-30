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
    // Launched from a terminal that is itself inside a `zmx` session — `open` from a
    // graphcode loop's own shell, say — the app inherits that session's `ZMX_SESSION`.
    // Every terminal surface then inherits it in turn, and `zmx attach` reads it as
    // "you are already inside a session": instead of attaching, it tries to *switch*
    // the inherited session, and every pane in the app dies with `session "…" does not
    // exist`. The app is never meaningfully inside a session, however it was launched,
    // so the variable is scrubbed before anything can pass it on.
    unsetenv("ZMX_SESSION")
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

    // ⌘, — the native home for the handful of things that were hardcoded until someone
    // reasonably wanted them different. See `SettingsView`.
    Settings {
      SettingsView()
    }
  }
}
