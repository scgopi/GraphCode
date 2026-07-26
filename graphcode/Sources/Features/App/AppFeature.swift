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
/// a supacode worktree owns its own terminal area) and `selectedProjectPath` (which
/// project's canvas is the fallback when no loop is open).
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var welcome = WelcomeFeature.State()
    var projects: IdentifiedArrayOf<ProjectFeature.State> = []
    var selectedProjectPath: String?
    var openLoop: LoopWorkspaceFeature.State?
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
    case welcome(WelcomeFeature.Action)
    case projects(IdentifiedActionOf<ProjectFeature>)
    case openLoop(LoopWorkspaceFeature.Action)
  }

  private enum CancelID { case daemonSubscription }

  @Dependency(\.orchestratorClient) var orchestratorClient
  @Dependency(\.terminalLayoutStore) var terminalLayoutStore

  var body: some ReducerOf<Self> {
    Scope(state: \.welcome, action: \.welcome) {
      WelcomeFeature()
    }
    Reduce { state, action in
      switch action {
      case .task:
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
          .run { _ in try? await orchestratorClient.send(.restoreOpenProjects) }
        )

      case .daemonEvent(let event):
        switch event {
        case .recentProjectsListed(let projects):
          state.welcome.recentProjects = projects
          return .none

        case .graphChanged(let graph):
          let path = graph.project.path
          guard state.projects[id: path] != nil else {
            // Not an already-open project — this snapshot is the reply to the
            // `.openProject` that just added it, i.e. this *is* "project opened."
            state.projects.append(ProjectFeature.State(graph: graph))
            state.selectedProjectPath = path
            state.openLoop = nil
            return .none
          }
          // Keep an open workspace's node in sync (title, presence dot, check bar) —
          // the workspace doesn't own a daemon subscription itself.
          if let openNodeID = state.openLoop?.node.id, let updated = graph.nodes[id: openNodeID] {
            state.openLoop?.node = updated
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

      case .projectCloseTapped(let path):
        removeFromSidebar(&state, path: path)
        return .run { _ in try? await orchestratorClient.send(.closeProject(path: path)) }

      case .projectRemoveTapped(let path):
        removeFromSidebar(&state, path: path)
        state.welcome.recentProjects.removeAll { $0.path == path }
        return .run { _ in try? await orchestratorClient.send(.forgetProject(path: path)) }

      case .projectDeleteLoopsConfirmed(let path):
        removeFromSidebar(&state, path: path)
        state.welcome.recentProjects.removeAll { $0.path == path }
        return .run { _ in try? await orchestratorClient.send(.deleteProjectGraph(path: path)) }

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
        state.openLoop = LoopWorkspaceFeature.State(node: node, layout: layout, projectPath: path)
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
        let command: GraphCommand = succeeded ? .nodeCheckApproved(id) : .nodeCheckRejected(id)
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: command))
        }

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

  /// Shared by all three context-menu verbs — they differ only in what they ask the
  /// daemon to forget, never in what leaves the sidebar. Selection and any open workspace
  /// have to be cleared too: both are cross-project (see this type's doc comment), so a
  /// workspace belonging to the removed project would otherwise stay on screen with
  /// nothing in the sidebar pointing at it.
  private func removeFromSidebar(_ state: inout State, path: String) {
    state.projects.remove(id: path)
    if state.openLoop?.projectPath == path {
      state.openLoop = nil
    }
    if state.selectedProjectPath == path {
      state.selectedProjectPath = state.projects.first?.id
    }
  }
}
