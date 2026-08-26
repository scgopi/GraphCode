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
      // ONE sheet modifier. A view honours only the last one attached, so the five this
      // replaced were quietly fighting: Manage would not dismiss, and the delete
      // confirmation retried against a sheet that would not go — a dialog flickering
      // once a second. `WorkspacesState.presentation` is the single source for which is
      // up, and it can only ever be one.
      .sheet(
        item: Binding(
          get: { store.workspaces.presentation },
          set: { if $0 == nil { store.send(.workspaces(.presentationDismissed)) } })
      ) { presentation in
        switch presentation {
        case .starter(let invitation):
          WorkspaceStarterView(
            store: store, workspace: store.workspaces.current,
            suggested: invitation.suggestedBackend)
        case .news(let version):
          WorkspaceNewsView(store: store, version: version)
        case .manage:
          ManageWorkspacesView(store: store)
        case .new:
          NewWorkspaceFormView(store: store)
        case .rename:
          RenameWorkspaceFormView(store: store)
        case .delete(let pending):
          DeleteWorkspaceConfirmView(store: store, pending: pending)
        }
      }
      // Another instance may have created or deleted one since this window last looked,
      // and the File menu is built from this list — so it is refreshed whenever the window
      // comes forward rather than only at launch.
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        store.send(.workspaces(.listRequested))
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
