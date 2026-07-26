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
/// every open project, so "which node's terminal (if any) is showing" and "which
/// project's canvas is the fallback" can't live inside any one `ProjectFeature.State`.
/// They live here instead: `detail` (non-nil = a node's terminal is showing) and
/// `selectedProjectPath` (which project's row is active — its canvas shows when
/// `detail` is nil).
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var welcome = WelcomeFeature.State()
    var projects: IdentifiedArrayOf<ProjectFeature.State> = []
    var selectedProjectPath: String?
    var detail: LoopNodeDetailFeature.State?
  }

  enum Action {
    case task
    case daemonEvent(DaemonEvent)
    case projectHeaderTapped(String)
    case welcome(WelcomeFeature.Action)
    case projects(IdentifiedActionOf<ProjectFeature>)
    case detail(LoopNodeDetailFeature.Action)
  }

  private enum CancelID { case daemonSubscription }

  @Dependency(\.orchestratorClient) var orchestratorClient

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
          .run { _ in try? await orchestratorClient.send(.listRecentProjects) }
        )

      case .daemonEvent(let event):
        switch event {
        case .recentProjectsListed(let projects):
          state.welcome.recentProjects = projects
          return .none

        case .graphChanged(let graph):
          let path = graph.project.path
          if state.projects[id: path] != nil {
            return .send(.projects(.element(id: path, action: .daemonEvent(event))))
          }
          // Not an already-open project — this snapshot is the reply to the
          // `.openProject` that just added it, i.e. this *is* "project opened."
          state.projects.append(ProjectFeature.State(graph: graph))
          state.selectedProjectPath = path
          state.detail = nil
          return .none

        case .errorOccurred(let message):
          state.welcome.errorMessage = message
          return .none
        }

      case .projectHeaderTapped(let path):
        state.selectedProjectPath = path
        state.detail = nil
        return .none

      case .projects(.element(id: let path, action: .nodeTapped(let nodeID))):
        // Time-based nodes run headlessly in graphcoded; there's no local interactive
        // session for a human to open here (see docs/04-cli-backends.md).
        guard let node = state.projects[id: path]?.graph.nodes[id: nodeID],
          node.state != .blocked,
          node.loopType == .turnBased
        else { return .none }
        state.selectedProjectPath = path
        state.detail = LoopNodeDetailFeature.State(node: node)
        return .none

      case .detail(.checkApproved):
        guard let id = state.detail?.node.id, let projectPath = state.selectedProjectPath
        else { return .none }
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckApproved(id)))
        }

      case .detail(.checkRejected):
        guard let id = state.detail?.node.id, let projectPath = state.selectedProjectPath
        else { return .none }
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckRejected(id)))
        }

      case .detail, .welcome, .projects:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      LoopNodeDetailFeature()
    }
    .forEach(\.projects, action: \.projects) {
      ProjectFeature()
    }
  }
}
