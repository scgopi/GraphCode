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
    /// What each known workspace holds, keyed by id — the switcher's second line.
    /// Refreshed with `known`, since both are read by the same gesture.
    var summaries: [String: Workspace.Summary] = [:]
    var isSwitcherPresented = false
    /// Up when this launch owes someone the news that workspaces exist — see
    /// `WorkspaceNews` for who that is. Carries the version so the badge can name it.
    var news: String?
    var isManaging = false
    /// The invitation this workspace was opened with; `nil` once answered, and on every
    /// workspace that predates the starter. See `WorkspaceStarter`.
    var starter: WorkspaceStarter.Invitation?
    /// The row selected in the starter — seeded from the invitation, applied on pick.
    var starterBackend: CLISessionBackendKind = .claudeCode
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
    case switcherPresented(Bool)
    case manageRequested
    case manageDismissed
    /// Raises the starter if this workspace was opened with an unanswered invitation.
    case starterChecked
    /// Asked once per launch, alongside the starter — the two are mutually exclusive by
    /// construction: the news is for the default workspace, the starter never is.
    case newsChecked
    case newsNotesTapped
    case newsDismissed
    case starterBackendPicked(CLISessionBackendKind)
    case starterDismissed
    case renameRequested(Workspace)
    /// The half that actually raises each sheet, sent once Manage has closed — see
    /// `handOff`. Separate cases rather than a flag, so the order is visible in a test.
    case newPresented
    case renamePresented(Workspace)
    case deletePresented(PendingDeletion)
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
  @Dependency(\.updateClient) var updateClient
  @Dependency(\.openURL) var openURL
  @Dependency(\.continuousClock) var clock

  /// Closes Manage Workspaces, then raises the sheet the row asked for.
  ///
  /// A view presents one sheet at a time. Rename and Delete are rows *inside* Manage, so
  /// flipping Manage off and the next sheet on in the same update left neither on screen:
  /// Manage stayed put and nothing came up — the same trap `GraphOverviewView`'s form
  /// hosts record, where a binding and its host changing together miss the transition.
  ///
  /// The wait is only paid when Manage is actually open, so the File menu and the
  /// switcher still raise their sheets immediately.
  private func handOff(
    _ state: inout AppFeature.State, to action: AppFeature.Action
  ) -> Effect<AppFeature.Action> {
    let wasManaging = state.workspaces.isManaging
    state.workspaces.isManaging = false
    return .run { send in
      if wasManaging { try? await clock.sleep(for: .milliseconds(280)) }
      await send(action)
    }
  }

  var body: some Reducer<AppFeature.State, AppFeature.Action> {
    Reduce { state, action in
      switch action {
      case .workspaces(.listRequested):
        state.workspaces.known = workspaces.list()
        state.workspaces.summaries = workspaces.summarize(state.workspaces.known)
        return .none

      case .workspaces(.switcherPresented(let isPresented)):
        state.workspaces.isSwitcherPresented = isPresented
        // Read on open, not on a timer: another instance may have created, deleted or
        // started using a workspace since this window last looked.
        guard isPresented else { return .none }
        return .send(.workspaces(.listRequested))

      case .workspaces(.manageRequested):
        state.workspaces.isManaging = true
        return .send(.workspaces(.listRequested))

      case .workspaces(.manageDismissed):
        state.workspaces.isManaging = false
        return .none

      case .workspaces(.starterChecked):
        guard let invitation = workspaces.starterInvitation() else { return .none }
        state.workspaces.starter = invitation
        state.workspaces.starterBackend = invitation.suggestedBackend
        return .none

      case .workspaces(.newsChecked):
        // Only in the default workspace. A workspace created since the upgrade has never
        // known a GraphCode without them, and `UserDefaults` is per app — so without this
        // every window on the machine would announce the same news.
        guard state.workspaces.current.isDefault else { return .none }
        let version = updateClient.currentVersion()
        guard WorkspaceNews.announceIfNeeded(currentVersion: version) else { return .none }
        state.workspaces.news = version
        return .none

      case .workspaces(.newsNotesTapped):
        state.workspaces.news = nil
        return .run { [openURL] _ in
          await openURL(WorkspaceNews.releasesURL)
        }

      case .workspaces(.newsDismissed):
        state.workspaces.news = nil
        return .none

      case .workspaces(.starterBackendPicked(let backend)):
        // Applied on the pick rather than on the button, the same as the tour's page:
        // there is no Save here, and a choice that only lands if you press the right
        // button afterwards is a choice that gets lost.
        state.workspaces.starterBackend = backend
        return .run { [apply = workspaces.applyDefaultBackend] _ in await apply(backend) }

      case .workspaces(.starterDismissed):
        // Skip counts as answered: someone who dismissed this does not want it again on
        // the next launch. Whatever is selected has already been applied.
        state.workspaces.starter = nil
        return .run { [finish = workspaces.finishStarter] _ in finish() }

      case .workspaces(.newRequested):
        return handOff(&state, to: .workspaces(.newPresented))

      case .workspaces(.newPresented):
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
        return handOff(&state, to: .workspaces(.renamePresented(workspace)))

      case .workspaces(.renamePresented(let workspace)):
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
        return handOff(
          &state,
          to: .workspaces(
            .deletePresented(
              AppFeature.PendingDeletion(
                workspace: workspace, contents: workspace.contents()))))

      case .workspaces(.deletePresented(let pending)):
        state.workspaces.pendingDeletion = pending
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
