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
/// every open project, so neither "which loops have an open terminal tab" nor "which
/// project's canvas is the fallback" can live inside any one `ProjectFeature.State`.
/// They live here instead: `openTabs` (every loop whose terminal has been opened, kept
/// alive — see `AppView` — until its tab is explicitly closed, the way supacode's
/// terminal tab bar keeps several terminals alive at once) and `activeTabID` (which
/// tab, if any, is the visible one — `selectedProjectPath`'s canvas shows when nil).
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var welcome = WelcomeFeature.State()
    var projects: IdentifiedArrayOf<ProjectFeature.State> = []
    var selectedProjectPath: String?
    var openTabs: IdentifiedArrayOf<LoopNodeDetailFeature.State> = []
    var activeTabID: UUID?

    /// Which open project a loop belongs to — `LoopNode`/`LoopNodeDetailFeature.State`
    /// don't carry their own project path, so this is how `AppFeature` resolves one
    /// when a tab (rather than a project-scoped sidebar row) is the thing that fired.
    func ownerProjectPath(ofNode nodeID: UUID) -> String? {
      projects.first(where: { $0.graph.nodes[id: nodeID] != nil })?.id
    }
  }

  enum Action {
    case task
    case daemonEvent(DaemonEvent)
    case projectHeaderTapped(String)
    case tabSelected(UUID)
    case tabClosed(UUID)
    case welcome(WelcomeFeature.Action)
    case projects(IdentifiedActionOf<ProjectFeature>)
    case openTabs(IdentifiedActionOf<LoopNodeDetailFeature>)
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
          guard state.projects[id: path] != nil else {
            // Not an already-open project — this snapshot is the reply to the
            // `.openProject` that just added it, i.e. this *is* "project opened."
            state.projects.append(ProjectFeature.State(graph: graph))
            state.selectedProjectPath = path
            state.activeTabID = nil
            return .none
          }
          // Keep any already-open tab for one of this project's loops in sync (title,
          // presence dot, check bar) — a tab doesn't own a daemon subscription itself.
          for node in graph.nodes where state.openTabs[id: node.id] != nil {
            state.openTabs[id: node.id]?.node = node
          }
          return .send(.projects(.element(id: path, action: .daemonEvent(event))))

        case .errorOccurred(let message):
          state.welcome.errorMessage = message
          return .none
        }

      case .projectHeaderTapped(let path):
        state.selectedProjectPath = path
        state.activeTabID = nil
        return .none

      case .tabSelected(let id):
        state.activeTabID = id
        if let path = state.ownerProjectPath(ofNode: id) {
          state.selectedProjectPath = path
        }
        return .none

      case .tabClosed(let id):
        let closedIndex = state.openTabs.index(id: id)
        state.openTabs.remove(id: id)
        if state.activeTabID == id {
          // Browser-tab convention: fall back to the tab that took this one's place,
          // else the one before it, else nothing (canvas/welcome shows instead).
          if let closedIndex, state.openTabs.indices.contains(closedIndex) {
            state.activeTabID = state.openTabs[closedIndex].id
          } else {
            state.activeTabID = state.openTabs.last?.id
          }
        }
        return .none

      case .projects(.element(id: let path, action: .nodeTapped(let nodeID))):
        // Time-based nodes run headlessly in graphcoded; there's no local interactive
        // session for a human to open here (see docs/04-cli-backends.md).
        guard let node = state.projects[id: path]?.graph.nodes[id: nodeID],
          node.state != .blocked,
          node.loopType == .turnBased
        else { return .none }
        if state.openTabs[id: nodeID] == nil {
          state.openTabs.append(LoopNodeDetailFeature.State(node: node))
        }
        state.activeTabID = nodeID
        state.selectedProjectPath = path
        return .none

      case .openTabs(.element(id: let nodeID, action: .checkApproved)):
        guard let projectPath = state.ownerProjectPath(ofNode: nodeID) else { return .none }
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckApproved(nodeID)))
        }

      case .openTabs(.element(id: let nodeID, action: .checkRejected)):
        guard let projectPath = state.ownerProjectPath(ofNode: nodeID) else { return .none }
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckRejected(nodeID)))
        }

      case .openTabs, .welcome, .projects:
        return .none
      }
    }
    .forEach(\.projects, action: \.projects) {
      ProjectFeature()
    }
    .forEach(\.openTabs, action: \.openTabs) {
      LoopNodeDetailFeature()
    }
  }
}
