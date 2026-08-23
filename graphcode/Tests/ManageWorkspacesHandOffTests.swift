import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Rename and Delete are rows inside Manage Workspaces, and a view presents one sheet at
/// a time. Flipping Manage off and the next sheet on in the same update left neither on
/// screen — Manage stayed put and nothing came up. Manage closes first now, and the sheet
/// it hands to comes up once it has gone.
@Suite
struct ManageWorkspacesHandOffTests {
  private func workspace(_ slug: String) -> Workspace {
    Workspace(slug: slug, url: URL(fileURLWithPath: "/tmp/.graphcode-\(slug)"))
  }

  private func managing(_ workspaces: [Workspace]) -> AppFeature.State {
    var state = AppFeature.State()
    state.workspaces.known = [.default] + workspaces
    state.workspaces.isManaging = true
    return state
  }

  @Test
  @MainActor
  func renameClosesManageBeforeItsOwnSheetComesUp() async {
    let work = workspace("work")
    let clock = TestClock()
    let store = TestStore(initialState: managing([work])) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.renameRequested(work)))
    // Manage is gone immediately; the rename sheet is not up yet — that is the whole
    // point, and doing both at once is what broke it.
    #expect(!store.state.workspaces.isManaging)
    #expect(store.state.workspaces.renaming == nil)

    await clock.advance(by: .milliseconds(280))
    await store.receive(\.workspaces.renamePresented)
    #expect(store.state.workspaces.renaming == work)
    #expect(store.state.workspaces.renameDraft == "work")
  }

  @Test
  @MainActor
  func deleteClosesManageBeforeItsConfirmation() async {
    let work = workspace("work")
    let clock = TestClock()
    let store = TestStore(initialState: managing([work])) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.deleteRequested(work)))
    #expect(!store.state.workspaces.isManaging)
    #expect(store.state.workspaces.pendingDeletion == nil)

    await clock.advance(by: .milliseconds(280))
    await store.receive(\.workspaces.deletePresented)
    #expect(store.state.workspaces.pendingDeletion?.workspace == work)
  }

  @Test
  @MainActor
  func aRefusedRowLeavesManageOpen() async {
    // The reason is shown on the row, so there is nothing to hand off to — closing Manage
    // would throw away the list someone is working through.
    let clock = TestClock()
    let store = TestStore(initialState: managing([])) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.renameRequested(.default)))
    #expect(store.state.workspaces.isManaging)
    #expect(store.state.workspaces.changeFailure != nil)
    #expect(store.state.workspaces.renaming == nil)
  }

  @Test
  @MainActor
  func withoutManageOpenTheSheetComesUpWithoutWaiting() async {
    // The File menu and the switcher raise their sheets directly, and must not pay for a
    // dismissal that is not happening.
    let clock = TestClock()
    let store = TestStore(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.newRequested))
    await store.receive(\.workspaces.newPresented)
    #expect(store.state.workspaces.isCreating)
  }
}
