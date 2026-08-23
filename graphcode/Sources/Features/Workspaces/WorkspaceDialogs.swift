import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Every dialog the workspace surfaces raise, applied to `AppView`'s dialog host — the
/// same arrangement `UpdateDialogs` uses, and here it is load-bearing rather than tidy:
/// inlined in `AppView.body`, four sheets, a confirmation and an alert pushed the
/// expression past what the SwiftUI type-checker will resolve, and the build failed with
/// "unable to type-check this expression in reasonable time".
///
/// They are hosted at window level, not on the surface that raises them, because that is
/// what lets a workspace be renamed from the sidebar's switcher and deleted from the File
/// menu and have both present the same dialog.
struct WorkspaceDialogs: ViewModifier {
  @Bindable var store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      // Which workspaces exist decides whether the sidebar names this one at all, so the
      // list is wanted before anything is drawn rather than when the switcher opens.
      .task { store.send(.workspaces(.listRequested)) }
      // A workspace opened for the first time asks its one question here — see
      // `WorkspaceStarter`. Never in the window that created it: the choice belongs to the
      // window it configures.
      .task { store.send(.workspaces(.starterChecked)) }
      // The other half of the same question — whoever was already here when workspaces
      // landed. Mutually exclusive with the starter by construction: this is default-only
      // and the starter never is.
      .task { store.send(.workspaces(.newsChecked)) }
      .sheet(
        isPresented: Binding(
          get: { store.workspaces.news != nil },
          set: { if !$0 { store.send(.workspaces(.newsDismissed)) } })
      ) {
        if let version = store.workspaces.news {
          WorkspaceNewsView(store: store, version: version)
        }
      }
      .sheet(
        isPresented: Binding(
          get: { store.workspaces.starter != nil },
          set: { if !$0 { store.send(.workspaces(.starterDismissed)) } })
      ) {
        if let starter = store.workspaces.starter {
          WorkspaceStarterView(
            store: store, workspace: store.workspaces.current,
            suggested: starter.suggestedBackend)
        }
      }
      .sheet(
        isPresented: Binding(
          get: { store.workspaces.isManaging },
          set: { if !$0 { store.send(.workspaces(.manageDismissed)) } })
      ) {
        ManageWorkspacesView(store: store)
      }
      .sheet(
        isPresented: Binding(
          get: { store.workspaces.isCreating },
          set: { if !$0 { store.send(.workspaces(.createCancelled)) } })
      ) {
        NewWorkspaceFormView(store: store)
      }
      .sheet(
        isPresented: Binding(
          get: { store.workspaces.renaming != nil },
          set: { if !$0 { store.send(.workspaces(.renameCancelled)) } })
      ) {
        RenameWorkspaceFormView(store: store)
      }
      // Another instance may have created or deleted one since this window last looked,
      // and the File menu is built from this list — so it is refreshed whenever the window
      // comes forward rather than only at launch.
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        store.send(.workspaces(.listRequested))
      }
      .confirmationDialog(
        "Delete the “\(store.workspaces.pendingDeletion?.workspace.name ?? "")” workspace?",
        isPresented: Binding(
          get: { store.workspaces.pendingDeletion != nil },
          set: { if !$0 { store.send(.workspaces(.deleteCancelled)) } }
        ),
        titleVisibility: .visible,
        presenting: store.workspaces.pendingDeletion
      ) { _ in
        Button("Delete Workspace", role: .destructive) {
          store.send(.workspaces(.deleteConfirmed))
        }
        Button("Cancel", role: .cancel) { store.send(.workspaces(.deleteCancelled)) }
      } message: { pending in
        Text(
          "\(pending.summary). Its terminal sessions are ended and its daemon stopped; "
            + "the folder moves to the Trash, where it stays recoverable.")
      }
      .alert(
        "That workspace can't be changed",
        isPresented: Binding(
          get: { store.workspaces.changeFailure != nil },
          set: { if !$0 { store.send(.workspaces(.changeFailureDismissed)) } }
        )
      ) {
        Button("OK", role: .cancel) { store.send(.workspaces(.changeFailureDismissed)) }
      } message: {
        Text(store.workspaces.changeFailure ?? "")
      }
  }
}
