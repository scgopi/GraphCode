import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The app's root feature (Phase 4, docs/07-roadmap.md#phase-4--projects) — a thin
/// router between `WelcomeFeature` (no project open) and `ProjectFeature` (one open
/// project), owning the **one** long-lived `orchestratorClient` subscription for the
/// app's whole lifetime. Before Phase 4 the app booted straight into a single
/// hardcoded graph and `GraphCanvasFeature` (now `ProjectFeature`) owned that
/// subscription itself; now that a project can be opened, closed, and reopened as a
/// different folder without restarting the app, the subscription has to outlive any
/// one project.
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var welcome = WelcomeFeature.State()
    var project: ProjectFeature.State?
  }

  enum Action {
    case task
    case daemonEvent(DaemonEvent)
    case welcome(WelcomeFeature.Action)
    case project(ProjectFeature.Action)
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
          guard state.project != nil else {
            // No project was open yet — this snapshot is the reply to the
            // `.openProject` that just got sent, i.e. this *is* "project opened."
            state.project = ProjectFeature.State(graph: graph)
            return .none
          }
          return .send(.project(.daemonEvent(event)))

        case .errorOccurred(let message):
          guard state.project != nil else {
            state.welcome.errorMessage = message
            return .none
          }
          return .send(.project(.daemonEvent(event)))
        }

      case .project(.closeProjectTapped):
        state.project = nil
        return .run { _ in try? await orchestratorClient.send(.listRecentProjects) }

      case .welcome, .project:
        return .none
      }
    }
    .ifLet(\.project, action: \.project) {
      ProjectFeature()
    }
  }
}
