import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The app's root feature — a thin router between `WelcomeFeature` (shown in the detail
/// pane once `projects` is empty) and however many projects are open at once (the
/// multi-project sidebar follow-up to Phase 4, docs/07-roadmap.md#phase-4--projects).
/// Owns the **one** long-lived `orchestratorClient` subscription for the app's whole
/// lifetime, and every open project's `ProjectFeature.State`.
///
/// Selection is cross-project by nature — the sidebar and detail pane are shared across
/// every open project, so neither "which loop's terminal workspace is open" nor "which
/// project's canvas is the fallback" can live inside any one `ProjectFeature.State`.
/// They live here instead: `openLoop` (at most one loop's whole terminal
/// workspace — tabs and splits, see `LoopWorkspaceFeature` — is open at a time, the way
/// a supacode worktree owns its own terminal area) and `detailSelection` (which canvas —
/// a folder's, or Quick Chats' — is the fallback when no loop is open).
@Reducer
struct AppFeature {
  /// Which canvas the detail pane falls back to when no loop's workspace is open.
  ///
  /// Quick Chats is a case rather than a reserved path because it is not a project and
  /// has no graph the daemon knows about — it's the app's own surface, drawn like a
  /// folder's canvas (see `QuickChatsCanvasView`) because that's what it is to a human:
  /// another place sessions live.
  enum DetailSelection: Equatable {
    case project(String)
    case quickChats
  }

  @ObservableState
  struct State: Equatable {
    var welcome = WelcomeFeature.State()
    var projects: IdentifiedArrayOf<ProjectFeature.State> = []
    var openLoop: LoopWorkspaceFeature.State?

    var detailSelection: DetailSelection?

    /// The selected *folder*, when the selection is one. Every caller that only ever
    /// deals in projects — opening one, closing one, following a node tap — keeps
    /// reading and writing selection through this; `nil` now also covers "Quick Chats",
    /// which no folder path could ever name.
    var selectedProjectPath: String? {
      get {
        if case .project(let path) = detailSelection { return path }
        return nil
      }
      set { detailSelection = newValue.map(DetailSelection.project) }
    }

    /// Ad-hoc backend sessions with no loop semantics — the sidebar's Quick Chats
    /// section. App-local (see `QuickChat`); loaded once at `.task` and saved on every
    /// mutation. A chat's workspace is opened through the same `openLoop` as a loop's,
    /// with a synthetic node — membership in this list is what marks it as a chat.
    var quickChats: IdentifiedArrayOf<QuickChat> = []

    /// Whether the open workspace is a quick chat rather than a graph node's loop.
    func isQuickChat(_ nodeID: UUID) -> Bool { quickChats[id: nodeID] != nil }

    /// The chat a rename prompt is up for, plus what has been typed so far, and the chat
    /// a delete confirmation is up for.
    ///
    /// In the reducer rather than in a view's `@State` for the same reason
    /// `pendingLoopRename` is: both the sidebar and the Quick Chats canvas start these
    /// verbs, only one of the two is on screen at any moment, and the dialogs are hosted
    /// once — by `AppView` — so neither surface can present a version of its own.
    var chatPendingRename: UUID?
    var draftChatTitle = ""
    var chatPendingDeletion: UUID?

    var pendingChatRename: QuickChat? { chatPendingRename.flatMap { quickChats[id: $0] } }
    var pendingChatDeletion: QuickChat? { chatPendingDeletion.flatMap { quickChats[id: $0] } }

    /// Up on first launch (`.task` checks the persisted flag) and whenever the
    /// sidebar's help button asks for it again.
    var showingOnboarding = false

    /// The loop ⌘⇧R landed on last, so pressing it again moves to the next one waiting
    /// instead of re-opening the same loop forever. View state only, and deliberately
    /// not persisted: a queue position is about this sitting, not about this graph.
    var lastReviewedNodeID: UUID?

    /// ⌘K's jump palette — see `AppFeature+JumpPalette.swift`.
    var isJumpPresented = false
    var jumpQuery = ""
    var jumpSelection = 0

    /// Check for Updates — see `AppFeature+Updates.swift`. `availableUpdate` is the
    /// offer alert's presentation; `offeredUpdate` is the same update kept past the
    /// alert's dismissal, because SwiftUI clears the presentation binding *before* it
    /// runs the tapped button's action (#35).
    var availableUpdate: AvailableUpdate?
    var offeredUpdate: AvailableUpdate?
    var updateNotice: UpdateNotice?
    var isCheckingForUpdates = false
    var updateInstallProgress: Double?
    var updateInstallFailure: String?
    var isUpdateReadyToRelaunch = false

    /// State changes seen since launch, for the activity strip — see
    /// `AppFeature+Activity.swift`. Bounded, and deliberately not persisted.
    var activityLog: [ActivityEvent] = []
    var activityFilterIsAttention = false

    /// The orchestrator's needs-attention rollup, across every open project
    /// (docs/05-orchestrator.md#monitoring-surface). Derived rather than stored: it's a
    /// pure function of the graphs the daemon already broadcasts, and a cached copy
    /// would just be one more thing that can disagree with them.
    ///
    /// Cross-project on purpose — a human with four projects open has one attention
    /// queue, not four.
    var attentionItems: [AttentionItem] {
      AttentionRollup.fullRollup(across: projects.map(\.graph))
    }

    /// The loop a "Delete Loop…" confirmation is currently up for, and which project it
    /// belongs to.
    ///
    /// The pending id lives on `ProjectFeature.State`, but the *dialog* has to be hosted
    /// by `AppView`: `ProjectCanvasView` is only rendered when that project's canvas is
    /// the visible detail pane, so a deletion started from the sidebar while a terminal
    /// was open would set the state with nothing anywhere to present it — the loop would
    /// silently never be deleted.
    var pendingLoopDeletion: (projectPath: String, node: LoopNode)? {
      for project in projects {
        guard let nodeID = project.nodePendingDeletion,
          let node = project.graph.nodes[id: nodeID]
        else { continue }
        return (project.id, node)
      }
      return nil
    }

    /// The loop a rename prompt is currently up for, which project it belongs to, and
    /// what has been typed into the field so far.
    ///
    /// Hosted here for the same reason the deletion dialog is: renaming is reachable from
    /// the sidebar, which is on screen even while a terminal fills the detail pane and
    /// that project's canvas isn't rendered at all.
    var pendingLoopRename: (projectPath: String, node: LoopNode, title: String)? {
      for project in projects {
        guard let nodeID = project.nodePendingRename,
          let node = project.graph.nodes[id: nodeID]
        else { continue }
        return (project.id, node, project.draftRenameTitle)
      }
      return nil
    }
  }

  enum Action {
    case task
    case daemonEvent(DaemonEvent)
    case projectHeaderTapped(String)
    /// Drop a project from the sidebar; it stays in recents, one click away under Add
    /// Folder.
    case projectCloseTapped(String)
    /// Close it and forget it from recents. Its saved loops survive.
    case projectRemoveTapped(String)
    /// Discard a project's saved loops for good — the view confirms before sending this.
    case projectDeleteLoopsConfirmed(String)
    /// Remove the project from GraphCode *and* move its folder to the Trash — the
    /// view's Delete dialog confirms before sending this. Trash rather than a hard
    /// delete, so a mistaken click stays recoverable.
    case projectDeleteFromDiskConfirmed(String)
    case projectDeleteFromDiskFailed(String)
    /// Step a project one slot up or down the sidebar. Within the sidebar only — the
    /// Graph row stays pinned at the front, and a project never leaves the list.
    case projectMoveUpTapped(String)
    case projectMoveDownTapped(String)
    case welcome(WelcomeFeature.Action)
    case projects(IdentifiedActionOf<ProjectFeature>)
    case openLoop(LoopWorkspaceFeature.Action)
    /// Jump straight to the loop that needs a human, from the monitor's rollup.
    case attentionItemTapped(AttentionItem)
    /// ⌘⇧R and the canvas rail's Review button — open the loop that has been waiting
    /// longest, then the next one on each press. See `reviewNextAttentionItem`.
    case reviewAttentionTapped
    /// The activity strip's "Only attention" filter — see `ActivityStripView`.
    case activityFilterToggled
    /// ⌘K's jump palette — see `JumpPalette`.
    case jumpPaletteRequested
    case jumpPaletteDismissed
    case jumpQueryChanged(String)
    case jumpSelectionMoved(Int)
    case jumpItemSelected(JumpPalette.Result)
    /// ⇧⌘] / ⇧⌘[ — step the open workspace to the next/previous loop in sidebar order,
    /// across every open project. See `stepOpenLoop`.
    case selectNextLoop
    case selectPreviousLoop
    /// The stop/kill affordance docs/05-orchestrator.md asks the monitor for.
    case stopNodeTapped(projectPath: String, nodeID: UUID)
    /// The first-launch terminology primer — see `OnboardingView`.
    case onboardingRequested
    case onboardingDismissed
    /// The app menu's "Check for Updates…" — see `AppFeature+Updates.swift`.
    case checkForUpdatesTapped
    case updateCheckCompleted(Result<AvailableUpdate?, any Error>)
    case updateDownloadTapped
    case updateReleaseNotesTapped
    case updateAlertDismissed
    case updateNoticeDismissed
    case updateInstallTapped
    case updateInstallProgressed(Double)
    case updateInstallFinished(Result<String, any Error>)
    case updateInstallFailureDismissed
    case updateRelaunchTapped
    case updateRelaunchDismissed
    /// The Quick Chats section's actions — see `State.quickChats`.
    case newQuickChatTapped
    /// The Quick Chats header row: shows the chats' own canvas, the way a folder row
    /// shows that folder's.
    case quickChatsTapped
    case quickChatTapped(UUID)
    /// Rename and delete, each startable from the sidebar row *or* the canvas card —
    /// which is why the prompt they raise lives in state; see `State.chatPendingRename`.
    case quickChatRenameRequested(UUID)
    case quickChatRenameTitleChanged(String)
    case quickChatRenameConfirmed
    case quickChatRenameCancelled
    case quickChatDeleteRequested(UUID)
    case quickChatDeleteConfirmed
    case quickChatDeleteCancelled
  }

  private enum CancelID { case daemonSubscription }

  @Dependency(\.orchestratorClient) var orchestratorClient
  @Dependency(\.terminalLayoutStore) var terminalLayoutStore
  @Dependency(\.quickChatStore) var quickChatStore
  @Dependency(\.updateClient) var updateClient
  @Dependency(\.updateInstallClient) var updateInstallClient
  @Dependency(\.openURL) var openURL
  /// Only for the cases where a workspace goes away because the *loop* did. Merely
  /// switching to another loop leaves its surfaces alive on purpose — see
  /// `TerminalSurfaceStore` — but a deleted loop, or a closed project, is never coming
  /// back, and its terminals shouldn't sit in the cache waiting to age out.
  @Dependency(\.terminalSurfaceClient) var terminalSurfaceClient

  var body: some ReducerOf<Self> {
    Scope(state: \.welcome, action: \.welcome) {
      WelcomeFeature()
    }
    // The Quick Chats section, in `AppFeature+QuickChats.swift` — the same state and
    // actions, kept in one place of its own because chats are a whole surface (a sidebar
    // section, a canvas, and two dialogs) that has nothing to do with projects or graphs.
    quickChatsReducer
    jumpPaletteReducer
    updatesReducer
    Reduce { state, action in
      switch action {
      case .task:
        state.quickChats = IdentifiedArray(uniqueElements: quickChatStore.load())
        // Once, not every launch: the primer's value is on day one, and re-showing it
        // to someone who has loops running would read as the app forgetting them.
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
          state.showingOnboarding = true
        }
        return .merge(
          .run { send in
            for await event in orchestratorClient.connect() {
              await send(.daemonEvent(event))
            }
          }
          .cancellable(id: CancelID.daemonSubscription),
          .run { _ in try? await orchestratorClient.send(.listRecentProjects) },
          // Without this the sidebar comes up empty on every launch even though the
          // daemon has been persisting every project all along — the app just never
          // asked for them back. Each restored project arrives as an ordinary
          // `.graphChanged`, handled below.
          .run { _ in try? await orchestratorClient.send(.restoreOpenProjects) },
          // The global Orchestrator Graph is always resident, so the app joins it every
          // launch rather than restoring it — it isn't a folder anyone opened, and its
          // triggers have been running whether or not this window existed.
          .run { _ in try? await orchestratorClient.send(.openGlobalGraph) }
        )

      case .daemonEvent(let event):
        switch event {
        case .recentProjectsListed(let projects):
          state.welcome.recentProjects = projects
          return .none

        case .graphChanged(let graph):
          // A broadcast means the daemon is alive and answering — whatever failure
          // banner was up (a dead-daemon Add Folder, say) is stale now.
          state.welcome.errorMessage = nil
          let path = graph.project.path
          // Before the graph is replaced: what changed between the two is the only
          // record anyone has of *when* a loop changed state. See `recordActivity`.
          Self.recordActivity(
            previous: state.projects[id: path]?.graph, next: graph, path: path,
            at: Date(), into: &state.activityLog)
          guard state.projects[id: path] != nil else {
            // Not an already-open project — this snapshot is the reply to the
            // `.openProject` that just added it, i.e. this *is* "project opened."
            //
            // The Graph is pinned to the front rather than appended: it isn't a folder
            // anyone opened, it's the one row that's always there, and it arrives last
            // (the app asks for it after `.restoreOpenProjects`) so appending would
            // leave it below folders that came back from a previous session.
            if graph.isGlobal {
              state.projects.insert(ProjectFeature.State(graph: graph), at: 0)
            } else {
              state.projects.append(ProjectFeature.State(graph: graph))
            }
            state.selectedProjectPath = path
            state.openLoop = nil
            return .none
          }
          // Keep an open workspace's node in sync (title, presence dot, check bar) —
          // the workspace doesn't own a daemon subscription itself.
          if let openLoop = state.openLoop, openLoop.projectPath == path {
            if let updated = graph.nodes[id: openLoop.node.id] {
              state.openLoop?.node = updated
              // The rail's downstream list comes off this — a handoff drawn while the
              // terminal is up should appear there without reopening the workspace.
              state.openLoop?.graph = graph
            } else {
              // The loop was deleted out from under its own terminal — easy to do now
              // that the sidebar can delete a loop while its workspace is the visible
              // detail pane. Its `zmx` session has already been killed, so leaving the
              // workspace up would show a terminal for something that no longer exists.
              // Scoped to this node's own project: another project's broadcast says
              // nothing about whether this loop still exists.
              closeOpenWorkspace(&state)
              state.selectedProjectPath = path
            }
          }
          return .send(.projects(.element(id: path, action: .daemonEvent(event))))

        case .errorOccurred(let message):
          state.welcome.errorMessage = message
          return .none
        }

      case .projectHeaderTapped(let path):
        state.selectedProjectPath = path
        state.openLoop = nil
        return .none

      // None of the three verbs applies to the Graph: it's always resident in the daemon
      // whether or not a window is open, isn't in recents, and its reserved path isn't a
      // folder to forget. The sidebar doesn't offer them on that row — this is the
      // backstop, so no future caller can close the one row that's meant to always be
      // there.
      case .projectCloseTapped(let path):
        guard !isGlobal(path) else { return .none }
        removeFromSidebar(&state, path: path)
        return .run { _ in try? await orchestratorClient.send(.closeProject(path: path)) }

      case .projectRemoveTapped(let path):
        guard !isGlobal(path) else { return .none }
        removeFromSidebar(&state, path: path)
        state.welcome.recentProjects.removeAll { $0.path == path }
        return .run { _ in try? await orchestratorClient.send(.forgetProject(path: path)) }

      case .projectDeleteLoopsConfirmed(let path):
        guard !isGlobal(path) else { return .none }
        removeFromSidebar(&state, path: path)
        state.welcome.recentProjects.removeAll { $0.path == path }
        return .run { _ in try? await orchestratorClient.send(.deleteProjectGraph(path: path)) }

      case .projectDeleteFromDiskConfirmed(let path):
        // Never the Graph row, and never a remote project — its folder lives on
        // another machine, so "delete from disk" would be a lie about what happened.
        guard !isGlobal(path), RemoteProjectLocation.parse(projectPath: path) == nil
        else { return .none }
        removeFromSidebar(&state, path: path)
        state.welcome.recentProjects.removeAll { $0.path == path }
        return .run { send in
          try? await orchestratorClient.send(.deleteProjectGraph(path: path))
          try? await orchestratorClient.send(.forgetProject(path: path))
          do {
            try FileManager.default.trashItem(
              at: URL(fileURLWithPath: path), resultingItemURL: nil)
          } catch {
            await send(.projectDeleteFromDiskFailed(String(describing: error)))
          }
        }

      case .projectDeleteFromDiskFailed(let message):
        state.welcome.errorMessage = "Couldn't move the folder to the Trash: \(message)"
        return .none

      case .projectMoveUpTapped(let path):
        // Within its own sidebar section only: a local folder steps over local folders,
        // a remote repository over remote repositories, and the Graph row never moves.
        // The swap targets the nearest *same-section* neighbour, so entries of the
        // other kind sitting between them in the array are stepped over, not disturbed.
        guard let index = state.projects.index(id: path), !isGlobal(path),
          let target = sameSectionNeighbor(from: index, direction: -1, in: state.projects)
        else { return .none }
        state.projects.swapAt(index, target)
        return .none

      case .projectMoveDownTapped(let path):
        guard let index = state.projects.index(id: path), !isGlobal(path),
          let target = sameSectionNeighbor(from: index, direction: +1, in: state.projects)
        else { return .none }
        state.projects.swapAt(index, target)
        return .none

      case .attentionItemTapped(let item):
        // The rollup's whole purpose is getting a human to the loop, so it routes
        // through the same open-the-loop path a sidebar tap does rather than merely
        // selecting its project.
        return .send(
          .projects(.element(id: item.projectPath, action: .nodeTapped(item.nodeID))))

      case .activityFilterToggled:
        state.activityFilterIsAttention.toggle()
        return .none

      case .reviewAttentionTapped:
        guard let item = reviewNextAttentionItem(&state) else { return .none }
        return .send(.attentionItemTapped(item))

      // Every ⌘K action is handled by `jumpPaletteReducer`, in
      // `AppFeature+JumpPalette.swift` — listed here only so this switch stays exhaustive.
      case .jumpPaletteRequested, .jumpPaletteDismissed, .jumpQueryChanged,
        .jumpSelectionMoved, .jumpItemSelected:
        return .none

      case .selectNextLoop:
        return stepOpenLoop(state, by: 1)

      case .selectPreviousLoop:
        return stepOpenLoop(state, by: -1)

      case .stopNodeTapped(let projectPath, let nodeID):
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .stopNode(nodeID)))
        }

      case .onboardingRequested:
        state.showingOnboarding = true
        return .none

      case .onboardingDismissed:
        state.showingOnboarding = false
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        return .none

      // Every update action is handled by `updatesReducer`, in
      // `AppFeature+Updates.swift` — listed here only so this switch stays exhaustive.
      case .checkForUpdatesTapped, .updateCheckCompleted, .updateDownloadTapped,
        .updateReleaseNotesTapped, .updateAlertDismissed, .updateNoticeDismissed,
        .updateInstallTapped, .updateInstallProgressed, .updateInstallFinished,
        .updateInstallFailureDismissed, .updateRelaunchTapped, .updateRelaunchDismissed:
        return .none

      // Every Quick Chats action is handled by `quickChatsReducer`, in
      // `AppFeature+QuickChats.swift` — listed here only so this switch stays exhaustive
      // and a new action can't be added without deciding which of the two answers it.
      case .newQuickChatTapped, .quickChatsTapped, .quickChatTapped,
        .quickChatRenameRequested, .quickChatRenameTitleChanged, .quickChatRenameConfirmed,
        .quickChatRenameCancelled, .quickChatDeleteRequested, .quickChatDeleteConfirmed,
        .quickChatDeleteCancelled:
        return .none

      // When creating a new loop while another loop's workspace is open, inherit that
      // loop's backend. Matches `parentBackend: nil` only — the re-sent action carries
      // a value, so it falls through instead of looping.
      case .projects(.element(id: let path, action: .addNodeButtonTapped(parentBackend: nil))):
        guard let parentBackend = state.openLoop?.node.backend else { return .none }
        return .send(
          .projects(.element(id: path, action: .addNodeButtonTapped(parentBackend: parentBackend))))

      case .projects(.element(id: let path, action: .nodeTapped(let nodeID))):
        // Every loop type opens the same way. A time-based node used to be excluded
        // because it only existed as a headless `claude -p` the daemon fired on a timer;
        // now its recurrence runs inside an ordinary interactive session (see
        // `LoopNode.triggerPrompt`), so there's a real terminal to attach to — which is
        // the point, since watching and steering a running loop is most of its value.
        guard let node = state.projects[id: path]?.graph.nodes[id: nodeID],
          node.state != .blocked
        else { return .none }
        let layout = terminalLayoutStore.load(forNode: nodeID) ?? .defaultLayout(forNode: nodeID)
        state.openLoop = LoopWorkspaceFeature.State(
          node: node,
          graph: state.projects[id: path]?.graph ?? LoopGraph(scope: .global),
          layout: layout,
          projectPath: path,
          projectName: state.projects[id: path]?.graph.project.name ?? path)
        state.selectedProjectPath = path
        return .none

      // A loop's own primary Claude Code session exiting *is* its resolution — no
      // separate human approve/reject step. `LoopWorkspaceFeature` already updated
      // its local node state for this same action; telling `graphcoded` is this
      // level's job, since it's the one holding the connection, and it's what
      // actually triggers automatic outgoing-edge firing.
      case .openLoop(.primarySurfaceExited(let succeeded)):
        guard let id = state.openLoop?.node.id, let projectPath = state.selectedProjectPath
        else { return .none }
        // A chat's session ending resolves nothing — there is no node in any graph for
        // the daemon to update, so telling it would only earn an unknown-node error.
        guard !state.isQuickChat(id) else { return .none }
        let command: GraphCommand = succeeded ? .nodeCheckApproved(id) : .nodeCheckRejected(id)
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: command))
        }

      case .openLoop(.stopLoopTapped):
        guard let id = state.openLoop?.node.id, let path = state.openLoop?.projectPath
        else { return .none }
        return .send(.stopNodeTapped(projectPath: path, nodeID: id))

      case .openLoop(.showInGraphTapped):
        // Closing the workspace *without* ending its terminals: the loop keeps running,
        // you are just looking at the graph again. `closeOpenWorkspace` is the other
        // thing, for when the loop itself is going away.
        guard let path = state.openLoop?.projectPath else { return .none }
        state.openLoop = nil
        state.selectedProjectPath = path
        return .none

      case .openLoop(.railTargetTapped(let nodeID)):
        guard let path = state.openLoop?.projectPath else { return .none }
        return .send(.projects(.element(id: path, action: .nodeTapped(nodeID))))

      case .openLoop, .welcome, .projects:
        return .none
      }
    }
    .ifLet(\.openLoop, action: \.openLoop) {
      LoopWorkspaceFeature()
    }
    .forEach(\.projects, action: \.projects) {
      ProjectFeature()
    }
  }
}

// The reducer's helpers — an extension so the type body stays inside the lint budget as
// the state and actions above keep growing.
extension AppFeature {
  /// Steps the open workspace to another loop, in the order the sidebar draws them —
  /// every open project's nodes, flattened — wrapping at the ends and skipping blocked
  /// nodes, the same rule a direct `.nodeTapped` applies. With no workspace open it
  /// lands on the first (or last) loop, so the shortcut also *opens* a loop from a
  /// canvas. Routes through `.nodeTapped` rather than setting `openLoop` itself, so
  /// keyboard and click cannot come to open a workspace two different ways.
  private func stepOpenLoop(_ state: State, by offset: Int) -> Effect<Action> {
    let loops = state.projects.flatMap { project in
      project.graph.nodes
        .filter { $0.state != .blocked }
        .map { (projectPath: project.id, nodeID: $0.id) }
    }
    guard !loops.isEmpty else { return .none }
    let current = state.openLoop.flatMap { open in
      loops.firstIndex { $0.nodeID == open.node.id }
    }
    let index: Int
    if let current {
      index = ((current + offset) % loops.count + loops.count) % loops.count
    } else {
      index = offset > 0 ? 0 : loops.count - 1
    }
    let target = loops[index]
    // The only loop there is, already open — reopening it would just rebuild the same
    // workspace under the user's keystroke.
    guard target.nodeID != state.openLoop?.node.id else { return .none }
    return .send(.projects(.element(id: target.projectPath, action: .nodeTapped(target.nodeID))))
  }

  /// The next loop for a human to look at: oldest waiting first, then the one after it
  /// on each press, wrapping when the queue runs out.
  ///
  /// Oldest-first and not worst-first, which is what the *list* is ordered by. A queue
  /// you work through is not a list you read: the thing ignored longest is the one to
  /// do next, and it also guarantees repeat presses move — a worst-first cursor would
  /// land on the same failure every time until someone dealt with it.
  ///
  /// Cycling on the node id rather than an index: the queue is rebuilt from live graphs
  /// between presses, and an index into a list that just lost an entry points at a
  /// different loop than the one it did a moment ago.
  private func reviewNextAttentionItem(_ state: inout State) -> AttentionItem? {
    let queue = state.attentionItems.oldestFirst
    guard !queue.isEmpty else {
      state.lastReviewedNodeID = nil
      return nil
    }
    let previous = state.lastReviewedNodeID.flatMap { id in
      queue.firstIndex { $0.nodeID == id }
    }
    let item = queue[previous.map { ($0 + 1) % queue.count } ?? 0]
    state.lastReviewedNodeID = item.nodeID
    return item
  }

  /// Shared by all three context-menu verbs — they differ only in what they ask the
  /// daemon to forget, never in what leaves the sidebar. Selection and any open workspace
  /// have to be cleared too: both are cross-project (see this type's doc comment), so a
  /// workspace belonging to the removed project would otherwise stay on screen with
  /// nothing in the sidebar pointing at it.
  private func isGlobal(_ path: String) -> Bool { path == LoopGraphScope.globalPath }

  /// Closes the open workspace *and ends its terminals* — for when the loop itself is
  /// gone, as opposed to merely not being the one on screen any more. Not `private`
  /// because a deleted chat needs the same treatment and lives in the other file.
  func closeOpenWorkspace(_ state: inout State) {
    guard let openLoop = state.openLoop else { return }
    terminalSurfaceClient.retire(openLoop.layout.tabs.flatMap { $0.surfaces.map(\.id) })
    state.openLoop = nil
  }

  /// The nearest project on the given side of `index` that lives in the same sidebar
  /// section — local folders and remote repositories are separate sections, and a move
  /// must not carry a project across the divider. `nil` when there's nothing of its
  /// kind left in that direction (or only the pinned Graph row).
  private func sameSectionNeighbor(
    from index: Int, direction: Int, in projects: IdentifiedArrayOf<ProjectFeature.State>
  ) -> Int? {
    let isRemote = RemoteProjectLocation.parse(projectPath: projects[index].id) != nil
    var candidate = index + direction
    while candidate >= 0 && candidate < projects.count {
      let project = projects[candidate]
      if project.graph.isGlobal { return nil }
      if (RemoteProjectLocation.parse(projectPath: project.id) != nil) == isRemote {
        return candidate
      }
      candidate += direction
    }
    return nil
  }

  private func removeFromSidebar(_ state: inout State, path: String) {
    state.projects.remove(id: path)
    if state.openLoop?.projectPath == path {
      closeOpenWorkspace(&state)
    }
    if state.selectedProjectPath == path {
      state.selectedProjectPath = state.projects.first?.id
    }
  }
}
