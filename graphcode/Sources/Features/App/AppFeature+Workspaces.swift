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
    /// instance is for — so this is fixed for the life of the process. A `var` only so a
    /// test can state which workspace it is asking about.
    var current: Workspace = .current
    var isCreating = false
    var draftName = ""
    /// What is wrong with `draftName`, said while it is being typed rather than after
    /// Create is pressed.
    var problem: String?
    /// The workspace a Delete confirmation is up for, with what it would take with it —
    /// counted when the dialog opens, since the numbers come off disk.
    var pendingDeletion: PendingDeletion?
    /// A refusal or a failure from the last deletion attempt, shown as an alert. Distinct
    /// from `problem`, which is about a name being typed.
    var deletionFailure: String?

    /// Whether this instance is the one that offers and installs app updates.
    ///
    /// Only the default workspace does. Every workspace is the same bundle in
    /// `/Applications`, so an update is not per-workspace news — with three open, the
    /// same banner appears three times and three windows race to swap one app. Worse,
    /// `UpdateInstallClient.relaunch` reopens the app with no `GRAPHCODE_SUPPORT_DIR`:
    /// a named workspace that updated itself would come back as the default one, which
    /// reads as the update having thrown its projects away.
    var managesUpdates: Bool { current.isDefault }

    /// Whether to name the workspace in the UI at all. A machine with one workspace has
    /// no ambiguity to resolve, and a permanent "Default" chip would be noise on every
    /// install that never uses this.
    var isWorthShowing: Bool { !current.isDefault || known.count > 1 }
  }

  /// One workspace and what deleting it costs, held while the confirmation is up.
  struct PendingDeletion: Equatable {
    var workspace: Workspace
    var contents: Workspace.Contents

    /// "2 projects and 14 loops" — the sentence the dialog needs, with the plurals right
    /// and an empty workspace saying so rather than reading "0 projects and 0 loops".
    var summary: String {
      guard contents.projects > 0 || contents.loops > 0 else { return "It has nothing in it" }
      let projects = "\(contents.projects) project\(contents.projects == 1 ? "" : "s")"
      let loops = "\(contents.loops) loop\(contents.loops == 1 ? "" : "s")"
      return "It holds \(projects) and \(loops)"
    }
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
    case deleteRequested(Workspace)
    case deleteConfirmed
    case deleteCancelled
    case deletionFailureDismissed
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

      case .workspaces(.deleteRequested(let workspace)):
        if let refusal = workspace.deletionRefusal(current: state.workspaces.current) {
          state.workspaces.deletionFailure = refusal.localizedDescription
          return .none
        }
        state.workspaces.pendingDeletion = AppFeature.PendingDeletion(
          workspace: workspace, contents: workspace.contents())
        return .none

      case .workspaces(.deleteConfirmed):
        guard let pending = state.workspaces.pendingDeletion else { return .none }
        state.workspaces.pendingDeletion = nil
        do {
          try workspaces.delete(pending.workspace)
        } catch {
          state.workspaces.deletionFailure = error.localizedDescription
        }
        state.workspaces.known = workspaces.list()
        return .none

      case .workspaces(.deleteCancelled):
        state.workspaces.pendingDeletion = nil
        return .none

      case .workspaces(.deletionFailureDismissed):
        state.workspaces.deletionFailure = nil
        return .none

      default:
        return .none
      }
    }
  }
}
