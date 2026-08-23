import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Which workspace offers app updates.
///
/// Only the default one. Every workspace is the same bundle in `/Applications`, so an
/// update is not per-workspace news: with three open, the same banner appears three
/// times and three windows race to swap one app. And `UpdateInstallClient.relaunch`
/// reopens the app with no `GRAPHCODE_SUPPORT_DIR`, so a named workspace that updated
/// itself would come back as the default one — which reads as the update having thrown
/// its projects away.
///
/// That the default workspace still checks is covered by `CheckForUpdatesTests`, whose
/// stores are all in it.
@Suite
struct WorkspaceUpdateGatingTests {
  private func state(inWorkspace workspace: Workspace) -> AppFeature.State {
    var state = AppFeature.State()
    state.workspaces.current = workspace
    return state
  }

  private var namedWorkspace: Workspace {
    Workspace(slug: "work", url: URL(fileURLWithPath: "/tmp/.graphcode-work"))
  }

  @Test
  func theDefaultWorkspaceIsTheOneThatManagesUpdates() {
    #expect(AppFeature.State().workspaces.managesUpdates)
    #expect(!state(inWorkspace: namedWorkspace).workspaces.managesUpdates)
  }

  @Test
  @MainActor
  func aNamedWorkspaceNeitherChecksOnItsOwnNorWhenAsked() async {
    // Both entry points, and the dependencies are left unimplemented on purpose: a check
    // that reached GitHub from here would fail the test by calling one of them.
    let store = TestStore(initialState: state(inWorkspace: namedWorkspace)) {
      AppFeature()
    }

    await store.send(.checkForUpdatesInBackground)
    #expect(!store.state.isCheckingForUpdates)

    // The menu item is disabled in a named workspace; this is the backstop behind it.
    await store.send(.checkForUpdatesTapped)
    #expect(!store.state.isCheckingForUpdates)
    #expect(store.state.offeredUpdate == nil)
  }

}
