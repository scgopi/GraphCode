import ComposableArchitecture
import Dependencies
import Foundation
import GraphcodeKit

extension AppFeature {
  /// What this instance knows about the workspaces on the machine — the switcher's list,
  /// which one is ours, and the New Workspace sheet while it is up.
  @ObservableState
  struct WorkspacesState: Equatable {
    /// Refreshed when the switcher is opened rather than watched: workspaces are created
    /// by a human every few weeks, and the alternative is a directory watcher on `$HOME`.
    var known: [Workspace] = []
    /// Read once. A running app cannot change workspace — that is what launching another
    /// instance is for — so this is fixed for the life of the process.
    let current: Workspace = .current
    var isCreating = false
    var draftName = ""
    /// What is wrong with `draftName`, said while it is being typed rather than after
    /// Create is pressed.
    var problem: String?

    /// Whether to name the workspace in the UI at all. A machine with one workspace has
    /// no ambiguity to resolve, and a permanent "Default" chip would be noise on every
    /// install that never uses this.
    var isWorthShowing: Bool { !current.isDefault || known.count > 1 }
  }

  /// The workspace half of the app's actions, nested so the whole surface costs
  /// `AppFeature.Action` a single case — same arrangement as `Worktrees`.
  @CasePathable
  enum Workspaces {
    case listRequested
    case newRequested
    case draftNameChanged(String)
    case createCancelled
    case createConfirmed
    /// Raise (or launch) the instance that owns this workspace.
    case switchRequested(Workspace)
  }
}

/// Listed alongside the app's other split-out reducers in `AppFeature.body`.
struct AppWorkspacesReducer: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  @Dependency(\.workspaceClient) var workspaces

  var body: some Reducer<AppFeature.State, AppFeature.Action> {
    Reduce { state, action in
      switch action {
      case .workspaces(.listRequested):
        state.workspaces.known = workspaces.list()
        return .none

      case .workspaces(.newRequested):
        state.workspaces.draftName = ""
        state.workspaces.problem = nil
        state.workspaces.isCreating = true
        return .none

      case .workspaces(.draftNameChanged(let name)):
        state.workspaces.draftName = name
        // An empty field is not yet a mistake — it's a sheet that has just opened.
        state.workspaces.problem =
          name.isEmpty ? nil : Workspace.problem(name: name)?.localizedDescription
        return .none

      case .workspaces(.createCancelled):
        state.workspaces.isCreating = false
        return .none

      case .workspaces(.createConfirmed):
        do {
          let created = try workspaces.create(state.workspaces.draftName)
          state.workspaces.isCreating = false
          state.workspaces.draftName = ""
          state.workspaces.known = workspaces.list()
          return .run { [open = workspaces.open] _ in open(created) }
        } catch {
          state.workspaces.problem = error.localizedDescription
          return .none
        }

      case .workspaces(.switchRequested(let workspace)):
        guard workspace.id != state.workspaces.current.id else { return .none }
        return .run { [open = workspaces.open] _ in open(workspace) }

      default:
        return .none
      }
    }
  }
}
