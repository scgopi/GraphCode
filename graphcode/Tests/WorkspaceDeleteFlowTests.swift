import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The delete and rename flows out of Manage Workspaces, after the confirmation became a
/// case of the window's one sheet.
///
/// The history these pin: the confirmation was a `confirmationDialog` raised while the
/// Manage sheet dismissed — a second presentation primitive, which AppKit deferred and
/// re-attempted (the dialog that came back seconds after being dismissed) — and its
/// Delete button ran after its own binding had cleared `pendingDeletion` (#35), so it
/// deleted nothing, which kept the workspace in every list that led back to the dialog.
@Suite
struct WorkspaceDeleteFlowTests {
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
  func deleteSwapsManageForTheConfirmationInOneUpdate() async {
    let work = workspace("work")
    let store = TestStore(initialState: managing([work])) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.workspaces(.deleteRequested(work)))

    // Both in the same update: the single `sheet(item:)` owns the morph from `.manage`
    // to `.delete`, so there is no window where two presentations negotiate — which is
    // where every earlier version of this flow went wrong.
    #expect(!store.state.workspaces.isManaging)
    #expect(store.state.workspaces.pendingDeletion?.workspace == work)
    if case .delete(let pending) = store.state.workspaces.presentation {
      #expect(pending.workspace == work)
    } else {
      Issue.record(
        "expected .delete, got \(String(describing: store.state.workspaces.presentation))")
    }
  }

  @Test
  @MainActor
  func confirmingActuallyDeletes() async {
    // The #35 regression: the dialog's Delete button read state its own dismissal had
    // already cleared, so nothing was ever deleted. A sheet button reads what is there.
    let work = workspace("work")
    let deleted = LockIsolated<[Workspace]>([])
    let store = TestStore(initialState: managing([work])) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.delete = { w in deleted.withValue { $0.append(w) } }
      $0.workspaceClient.list = { [.default] }
      $0.workspaceClient.summarize = { _ in [:] }
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.deleteRequested(work)))
    await store.send(.workspaces(.deleteConfirmed))

    // Dismissed before the tear-down, not after: the confirmation must never sit frozen
    // over a launchctl bootout that can take tens of seconds.
    #expect(store.state.workspaces.pendingDeletion == nil)
    #expect(store.state.workspaces.presentation == nil)

    await store.receive(\.workspaces.deleteFinished)
    #expect(deleted.value == [work])
  }

  @Test
  @MainActor
  func cancellingOrDismissingEndsTheFlowForGood() async {
    let work = workspace("work")
    let deleted = LockIsolated(0)
    let store = TestStore(initialState: managing([work])) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.delete = { _ in deleted.withValue { $0 += 1 } }
    }
    store.exhaustivity = .off

    await store.send(.workspaces(.deleteRequested(work)))
    await store.send(.workspaces(.deleteCancelled))
    #expect(store.state.workspaces.pendingDeletion == nil)
    #expect(store.state.workspaces.presentation == nil)

    // Escape / click-outside routes through the sheet's one dismissal action, which must
    // land on the delete case now that it is a presentation.
    await store.send(.workspaces(.deleteRequested(work)))
    await store.send(.workspaces(.presentationDismissed))
    await store.receive(\.workspaces.deleteCancelled)
    #expect(store.state.workspaces.pendingDeletion == nil)

    // Nothing scheduled, nothing in flight: there is no effect left to bring it back.
    await store.finish()
    #expect(deleted.value == 0)
  }

  @Test
  @MainActor
  func renameSwapsManageForItsSheetInOneUpdate() async {
    let work = workspace("work")
    let store = TestStore(initialState: managing([work])) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.workspaces(.renameRequested(work)))
    #expect(!store.state.workspaces.isManaging)
    #expect(store.state.workspaces.renaming == work)
    #expect(store.state.workspaces.renameDraft == "work")
  }

  @Test
  @MainActor
  func aRefusedRowLeavesManageOpen() async {
    // The reason is printed on the row; closing the list someone is working through to
    // show nothing would be worse than doing nothing.
    let store = TestStore(initialState: managing([])) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.workspaces(.renameRequested(.default)))
    #expect(store.state.workspaces.isManaging)
    #expect(store.state.workspaces.changeFailure != nil)
    #expect(store.state.workspaces.renaming == nil)
  }

  @Test
  @MainActor
  func aDoubleTapAsksOnce() async {
    let work = workspace("work")
    let store = TestStore(initialState: managing([work])) { AppFeature() }
    store.exhaustivity = .off

    await store.send(.workspaces(.deleteRequested(work)))
    let first = store.state.workspaces.pendingDeletion
    await store.send(.workspaces(.deleteRequested(work)))
    #expect(store.state.workspaces.pendingDeletion == first)
  }
}
