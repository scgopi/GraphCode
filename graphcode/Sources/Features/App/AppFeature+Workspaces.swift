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
    /// The workspace being renamed, and the name being typed for it. `nil` means the
    /// sheet is closed.
    var renaming: Workspace?
    var renameDraft = ""
    /// The other workspaces found open when Install was pressed, held while the app asks
    /// what to do about them. `nil` means nothing is being asked.
    var othersOpenForUpdate: [Workspace]?
    /// A refusal or a failure from the last rename or deletion, shown as an alert. One
    /// channel for both: the refusal's own sentence already names which was refused.
    /// Distinct from `problem`, which is about a name being typed.
    var changeFailure: String?

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
    case renameRequested(Workspace)
    case renameDraftChanged(String)
    case renameConfirmed
    case renameCancelled
    case deleteRequested(Workspace)
    case deleteConfirmed
    case deleteCancelled
    case changeFailureDismissed
    /// The three answers to "other workspaces are open" — see `UpdateDialogs`.
    case quitOthersForUpdate
    case updateWithoutQuittingOthers
    case othersForUpdateDismissed
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

      case .workspaces(.renameRequested(let workspace)):
        if let refusal = workspace.refusal(for: .rename, current: state.workspaces.current) {
          state.workspaces.changeFailure = refusal.localizedDescription
          return .none
        }
        state.workspaces.renaming = workspace
        // Prefilled with the current name: renaming is usually a correction, not a
        // fresh start, and an empty field would make you retype what you had.
        state.workspaces.renameDraft = workspace.name
        state.workspaces.problem = nil
        return .none

      case .workspaces(.renameDraftChanged(let name)):
        state.workspaces.renameDraft = name
        state.workspaces.problem =
          name.isEmpty ? nil : Workspace.problem(name: name)?.localizedDescription
        return .none

      case .workspaces(.renameCancelled):
        state.workspaces.renaming = nil
        state.workspaces.problem = nil
        return .none

      case .workspaces(.renameConfirmed):
        guard let workspace = state.workspaces.renaming else { return .none }
        do {
          _ = try workspaces.rename(workspace, state.workspaces.renameDraft)
          state.workspaces.renaming = nil
          state.workspaces.renameDraft = ""
          state.workspaces.known = workspaces.list()
        } catch {
          state.workspaces.problem = error.localizedDescription
        }
        return .none

      case .workspaces(.deleteRequested(let workspace)):
        if let refusal = workspace.refusal(for: .delete, current: state.workspaces.current) {
          state.workspaces.changeFailure = refusal.localizedDescription
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
          state.workspaces.changeFailure = error.localizedDescription
        }
        state.workspaces.known = workspaces.list()
        return .none

      case .workspaces(.deleteCancelled):
        state.workspaces.pendingDeletion = nil
        return .none

      case .workspaces(.changeFailureDismissed):
        state.workspaces.changeFailure = nil
        return .none

      case .workspaces(.quitOthersForUpdate):
        guard let others = state.workspaces.othersOpenForUpdate else { return .none }
        state.workspaces.othersOpenForUpdate = nil
        // The install waits for them: `quit` returns once they have gone (or once it
        // gives up on one), so the swap never lands under a live window.
        return .run { [quit = workspaces.quit] send in
          await quit(others)
          await send(.updateInstallConfirmed)
        }

      case .workspaces(.updateWithoutQuittingOthers):
        state.workspaces.othersOpenForUpdate = nil
        return .send(.updateInstallConfirmed)

      case .workspaces(.othersForUpdateDismissed):
        state.workspaces.othersOpenForUpdate = nil
        return .none

      default:
        return .none
      }
    }
  }
}
