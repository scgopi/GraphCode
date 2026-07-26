import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One open project's graph canvas — one of possibly several the sidebar shows at once
/// (multi-project sidebar follow-up to Phase 4, docs/07-roadmap.md#phase-4--projects).
///
/// Selection (which node's terminal is showing, if any) used to live here, back when
/// only one project could be open at a time — now that the sidebar can show several
/// projects sharing one detail pane, "what's selected" is inherently cross-project, so
/// it moved up to `AppFeature.State.detail`/`.selectedProjectPath`. `.nodeTapped`
/// is still declared here (both the sidebar's node rows and the canvas's node cards are
/// rendered off a project-scoped store), but this feature's own reducer does nothing
/// with it — it's purely a signal `AppFeature`'s parent `Reduce` intercepts.
///
/// Still mirrors whatever `graphcoded` broadcasts for this project rather than owning
/// graph state directly — node/edge-creation actions send a `GraphCommand` (wrapped in
/// `.graphCommand(projectPath:, command:)`) and wait for the resulting `.graphChanged`
/// broadcast; automatic `.handoff` firing happens in the daemon (see
/// `graphcoded/Sources/GraphStore.swift`). `nodePositions` stays local — canvas layout
/// is a UI concern the daemon has no reason to know about. `AppFeature` owns the one
/// daemon subscription for the app's whole lifetime and forwards this project's
/// `DaemonEvent`s in via `.daemonEvent`.
@Reducer
struct ProjectFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var graph: LoopGraph
    var nodePositions: [UUID: CGPoint] = [:]
    var showingNewNodeForm = false
    var draftLoopType: LoopType = .turnBased
    var draftTitle = ""
    var draftCheck = ""
    var draftPrompt = ""
    var connectionError: String?

    var id: String { graph.project.path }

    init(graph: LoopGraph) {
      self.graph = graph
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case daemonEvent(DaemonEvent)
    case addNodeButtonTapped
    case createNodeConfirmed
    case cancelNewNodeForm
    case nodeTapped(UUID)
    case edgeDrawn(from: UUID, to: UUID)
  }

  @Dependency(\.orchestratorClient) var orchestratorClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .daemonEvent(let event):
        switch event {
        case .graphChanged(let newGraph):
          state.connectionError = nil
          for node in newGraph.nodes where state.nodePositions[node.id] == nil {
            state.nodePositions[node.id] = Self.nextPosition(index: state.nodePositions.count)
          }
          state.graph = newGraph
        case .errorOccurred(let message):
          state.connectionError = message
        case .recentProjectsListed:
          break  // Not this feature's concern — AppFeature routes this to `welcome`.
        }
        return .none

      case .addNodeButtonTapped:
        state.draftLoopType = .turnBased
        state.draftTitle = ""
        state.draftCheck = ""
        state.draftPrompt = ""
        state.showingNewNodeForm = true
        return .none

      case .cancelNewNodeForm:
        state.showingNewNodeForm = false
        return .none

      case .createNodeConfirmed:
        guard !state.draftTitle.isEmpty else { return .none }
        let projectPath = state.graph.project.path
        let title = state.draftTitle
        switch state.draftLoopType {
        case .turnBased:
          guard !state.draftCheck.isEmpty else { return .none }
          let checkDescription = state.draftCheck
          state.showingNewNodeForm = false
          return .run { _ in
            try? await orchestratorClient.send(
              .graphCommand(
                projectPath: projectPath,
                command: .createTurnBasedNode(title: title, checkDescription: checkDescription)))
          }
        case .timeBased:
          // Only the prompt is required — it carries its own cadence, and graphcode
          // deliberately doesn't inspect it (a prompt with no `/loop` simply runs once).
          guard !state.draftPrompt.isEmpty else { return .none }
          let prompt = state.draftPrompt
          state.showingNewNodeForm = false
          return .run { _ in
            try? await orchestratorClient.send(
              .graphCommand(
                projectPath: projectPath,
                command: .createTimeBasedNode(title: title, prompt: prompt)))
          }
        case .goalBased, .proactive:
          // Not creatable yet — see docs/07-roadmap.md's deferred goal-based/proactive
          // node config UI. The picker only offers turn-based/time-based.
          return .none
        }

      case .nodeTapped:
        // Handled by `AppFeature`'s parent `Reduce`, which owns cross-project
        // selection — nothing to do here.
        return .none

      case .edgeDrawn(let from, let to):
        guard from != to else { return .none }
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .createEdge(from: from, to: to)))
        }
      }
    }
  }

  /// Simple grid layout for freshly synced nodes — real layout (force-directed,
  /// draggable repositioning) is future work; this just needs nodes to not overlap.
  private static func nextPosition(index: Int) -> CGPoint {
    let columns = 3
    let column = index % columns
    let row = index / columns
    return CGPoint(x: 160 + CGFloat(column) * 260, y: 140 + CGFloat(row) * 200)
  }
}
