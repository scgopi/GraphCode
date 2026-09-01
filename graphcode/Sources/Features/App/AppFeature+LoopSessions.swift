import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The Loop menu's verbs on a session — Stop Loop, Restart Session, Restart All
/// Sessions… — and the pane exit that resolves a loop. Restart kills a loop's `zmx` session and bring it back on the same transcript
/// (`GraphCommand.restartNode`), for the day `zmx` or a backend CLI was replaced under
/// every running loop. Stop lives here too because it is the same shape (a menu item, a
/// daemon command) and `AppFeature.swift` is at its lint budget.
///
/// A restart's app half is about panes, not sessions. A mounted agent pane reads its process
/// exiting as the loop resolving (`primarySurfaceExited`), and a retained one keeps that
/// callback after the loop was switched away from — so every affected surface is
/// retired *before* the daemon is asked, and the workspace that was open is remounted
/// only once the daemon has bumped the node's `sessionRestarts`, its word that the old
/// session is confirmed dead. Remounted any earlier, the pane would join the dying
/// session and resolve the very loop it was meant to bring back.
struct SessionRestart: Equatable {
  var isConfirmingAll = false
  /// The workspace closed for a restart, to be remounted once the daemon confirms.
  var pendingReopen: PendingReopen?

  struct PendingReopen: Equatable {
    var projectPath: String
    var nodeID: UUID
    /// The count the node carried when the workspace closed; the remount waits for it
    /// to move.
    var seenRestarts: Int
  }

  @CasePathable
  enum Action: Equatable {
    case openLoopTapped
    case allTapped
    case allConfirmed
    case allCancelled
  }
}

extension AppFeature {
  var loopSessionsReducer: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .stopNodeTapped(let projectPath, let nodeID):
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .stopNode(nodeID)))
        }

      case .openLoop(.stopLoopTapped):
        guard let id = state.openLoop?.node.id, let path = state.openLoop?.projectPath
        else { return .none }
        return .send(.stopNodeTapped(projectPath: path, nodeID: id))

      case .openLoop(.restartLoopTapped):
        return .send(.sessionRestart(.openLoopTapped))

      // A loop's own primary session exiting *is* its resolution — no separate human
      // approve/reject step. `LoopWorkspaceFeature` already updated its local node
      // state for this same action; telling `graphcoded` is this level's job, since it
      // holds the connection, and it's what fires the outgoing edges. The daemon has
      // the last word (`GraphStore.sessionPermitsResolution`), and the report is
      // logged here so a resolution nobody expected can be traced to the pane that
      // sent it.
      case .openLoop(.primarySurfaceExited(let succeeded)):
        guard let id = state.openLoop?.node.id, let projectPath = state.selectedProjectPath
        else { return .none }
        // A chat's session ending resolves nothing — there is no node in any graph for
        // the daemon to update, so telling it would only earn an unknown-node error.
        guard !state.isQuickChat(id) else { return .none }
        DialLog.record(
          session: SurfaceRef(id: id, launchesClaudeCode: true).zmxSessionName,
          dial: "pane", event: succeeded ? "exit-finished" : "exit-alive")
        // The pane that watched a restart's kill has nothing to say about the work.
        guard state.sessionRestart.pendingReopen?.nodeID != id else { return .none }
        let command: GraphCommand = succeeded ? .nodeCheckApproved(id) : .nodeCheckRejected(id)
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: command))
        }

      case .sessionRestart(.openLoopTapped):
        // A chat is not a node in any graph — the daemon has nothing to restart.
        guard let open = state.openLoop, !state.isQuickChat(open.node.id) else { return .none }
        let path = open.projectPath
        let nodeID = open.node.id
        closeForRestart(&state, reopening: open)
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: path, command: .restartNode(nodeID)))
        }

      case .sessionRestart(.allTapped):
        state.sessionRestart.isConfirmingAll = true
        return .none

      case .sessionRestart(.allCancelled):
        state.sessionRestart.isConfirmingAll = false
        return .none

      case .sessionRestart(.allConfirmed):
        state.sessionRestart.isConfirmingAll = false
        if let open = state.openLoop, !state.isQuickChat(open.node.id) {
          closeForRestart(&state, reopening: open)
        } else {
          closeOpenWorkspace(&state)
        }
        // Every retained surface, not just the open workspace's: a loop switched away
        // from keeps its pane, and that pane keeps the exit callback.
        terminalSurfaceClient.retireAll()
        let paths = Array(state.projects.ids)
        return .run { _ in
          for path in paths {
            try? await orchestratorClient.send(
              .graphCommand(projectPath: path, command: .restartSessions))
          }
        }

      case .daemonEvent(.graphChanged(let graph)):
        guard let pending = state.sessionRestart.pendingReopen,
          pending.projectPath == graph.project.path
        else { return .none }
        guard let node = graph.nodes[id: pending.nodeID] else {
          state.sessionRestart.pendingReopen = nil
          return .none
        }
        guard node.sessionRestarts > pending.seenRestarts else { return .none }
        state.sessionRestart.pendingReopen = nil
        // The human may have opened something else while the daemon worked; their
        // choice stands.
        guard state.openLoop == nil else { return .none }
        mountWorkspace(node: node, graph: graph, projectPath: pending.projectPath, &state)
        return .none

      // The daemon refusing the restart is the likeliest error to arrive while a
      // remount is pending, and a remount that never comes is what it should mean.
      case .daemonEvent(.errorOccurred):
        state.sessionRestart.pendingReopen = nil
        return .none

      default:
        return .none
      }
    }
  }

  private func closeForRestart(_ state: inout State, reopening open: LoopWorkspaceFeature.State) {
    let current =
      state.projects[id: open.projectPath]?.graph.nodes[id: open.node.id]?.sessionRestarts
      ?? open.node.sessionRestarts
    state.sessionRestart.pendingReopen = SessionRestart.PendingReopen(
      projectPath: open.projectPath, nodeID: open.node.id, seenRestarts: current)
    closeOpenWorkspace(&state)
    state.selectedProjectPath = open.projectPath
  }

  /// Puts a loop's workspace on screen — what a history step and a restart's remount
  /// share, minus the recording and the blocked-loop gate, which are `openNode`'s.
  func mountWorkspace(
    node: LoopNode, graph: LoopGraph, projectPath: String, _ state: inout State
  ) {
    let layout = terminalLayoutStore.load(forNode: node.id) ?? .defaultLayout(forNode: node.id)
    state.openLoop = LoopWorkspaceFeature.State(
      node: node,
      graph: graph,
      layout: layout,
      projectPath: projectPath,
      projectName: graph.project.name)
    state.openLoop?.seenArtifactoryPostID =
      LoopWorkspaceRail.loadSeenArtifactoryPost(forProjectPath: projectPath)
    state.selectedProjectPath = projectPath
  }
}
