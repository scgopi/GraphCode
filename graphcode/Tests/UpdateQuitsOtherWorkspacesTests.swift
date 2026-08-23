import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Installing an update while other workspaces are open.
///
/// Every workspace runs from the same copy in `/Applications`, so the install swaps the
/// bundle out from under any other open window — which is then executing pages that are
/// no longer on disk. So Install asks first, and both answers arrive as
/// `.updateInstallConfirmed`.
@Suite
struct UpdateQuitsOtherWorkspacesTests {
  private func workspace(_ slug: String) -> Workspace {
    Workspace(slug: slug, url: URL(fileURLWithPath: "/tmp/.graphcode-\(slug)"))
  }

  private func offeredState() -> AppFeature.State {
    var state = AppFeature.State()
    state.offeredUpdate = AvailableUpdate(
      version: "0.1.99", currentVersion: "0.1.46",
      downloadURL: URL(string: "https://example.invalid/graphcode.dmg")!,
      releaseNotesURL: URL(string: "https://example.invalid/notes")!)
    return state
  }

  @Test
  @MainActor
  func installAsksAboutOtherOpenWorkspacesBeforeSwappingTheBundle() async {
    let others = [workspace("work"), workspace("oss")]
    let store = TestStore(initialState: offeredState()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.otherOpen = { others }
    }

    // No install starts: `updateInstallClient` is left unimplemented, so a download that
    // began here would fail the test by calling it.
    await store.send(.updateInstallTapped) {
      $0.workspaces.othersOpenForUpdate = others
      $0.availableUpdate = nil
    }
    #expect(store.state.updateInstallProgress == nil)
  }

  @Test
  @MainActor
  func nothingIsAskedWhenThisIsTheOnlyWindow() async {
    let store = TestStore(initialState: offeredState()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.otherOpen = { [] }
    }
    store.exhaustivity = .off

    await store.send(.updateInstallTapped)
    await store.receive(\.updateInstallConfirmed)
    #expect(store.state.workspaces.othersOpenForUpdate == nil)
  }

  @Test
  @MainActor
  func quittingThemWaitsForThemToGoBeforeTheInstallRuns() async {
    let others = [workspace("work")]
    let quit = LockIsolated<[Workspace]>([])
    let store = TestStore(initialState: offeredState()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.otherOpen = { others }
      $0.workspaceClient.quit = { asked in quit.withValue { $0 = asked } }
    }
    store.exhaustivity = .off

    await store.send(.updateInstallTapped)
    await store.send(.workspaces(.quitOthersForUpdate))
    // The install only starts once `quit` has returned — that ordering is the whole
    // point, since the swap must not land under a live window.
    await store.receive(\.updateInstallConfirmed)
    #expect(quit.value == others)
    #expect(store.state.workspaces.othersOpenForUpdate == nil)
  }

  @Test
  @MainActor
  func installAnywayProceedsWithoutQuittingAnything() async {
    let others = [workspace("work")]
    let store = TestStore(initialState: offeredState()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.otherOpen = { others }
      $0.workspaceClient.quit = { _ in Issue.record("nothing should be asked to quit") }
    }
    store.exhaustivity = .off

    await store.send(.updateInstallTapped)
    await store.send(.workspaces(.updateWithoutQuittingOthers))
    await store.receive(\.updateInstallConfirmed)
    #expect(store.state.workspaces.othersOpenForUpdate == nil)
  }

  @Test
  @MainActor
  func cancellingLeavesEverythingAsItWas() async {
    let store = TestStore(initialState: offeredState()) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.otherOpen = { [self.workspace("work")] }
    }
    store.exhaustivity = .off

    await store.send(.updateInstallTapped)
    await store.send(.workspaces(.othersForUpdateDismissed))
    #expect(store.state.workspaces.othersOpenForUpdate == nil)
    #expect(store.state.updateInstallProgress == nil)
    // The offer survives a cancel — the update is still there to install later.
    #expect(store.state.offeredUpdate != nil)
  }

  @Test
  func theWindowsAreNamedRatherThanCounted() {
    // "2 other workspaces" does not answer the question someone actually has, which is
    // *which* windows are about to be quit.
    #expect(UpdateDialogs.list([workspace("work")]) == "work")
    #expect(UpdateDialogs.list([workspace("work"), workspace("oss")]) == "work and oss")
    #expect(
      UpdateDialogs.list([workspace("work"), workspace("oss"), workspace("side")])
        == "work, oss and side")
  }
}
