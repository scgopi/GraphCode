import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One open project's graph canvas + sidebar selection. Renamed from Phase 2/3's
/// `GraphCanvasFeature` in Phase 4 (docs/07-roadmap.md#phase-4--projects), when
/// graphcode grew a welcome screen and per-folder projects: `AppFeature` now owns the
/// one daemon subscription for the app's whole lifetime and forwards this project's
/// `DaemonEvent`s in via `.daemonEvent` — this feature no longer subscribes itself.
///
/// Still mirrors whatever `graphcoded` broadcasts for this project rather than owning
/// graph state directly — node/edge-creation and check-resolution actions send a
/// `GraphCommand` (wrapped in `.graphCommand(projectPath:, command:)`) and wait for the
/// resulting `.graphChanged` broadcast; automatic `.handoff` firing happens in the
/// daemon (see `graphcoded/Sources/GraphStore.swift`). `nodePositions` stays local —
/// canvas layout is a UI concern the daemon has no reason to know about.
@Reducer
struct ProjectFeature {
  @ObservableState
  struct State: Equatable {
    var graph: LoopGraph
    var nodePositions: [UUID: CGPoint] = [:]
    var detail: LoopNodeDetailFeature.State?
    var showingNewNodeForm = false
    var draftLoopType: LoopType = .turnBased
    var draftTitle = ""
    var draftCheck = ""
    var draftIntervalSeconds = "3600"
    var draftPrompt = ""
    var connectionError: String?

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
    case detailDismissed
    case closeProjectTapped
    case edgeDrawn(from: UUID, to: UUID)
    case detail(LoopNodeDetailFeature.Action)
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
          // Keep an open detail sheet's badge honest if the daemon resolved this node
          // from underneath it (e.g. a second window/CLI approved it first).
          if let detailID = state.detail?.node.id, let updated = newGraph.nodes[id: detailID] {
            state.detail?.node.state = updated.state
          }
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
        state.draftIntervalSeconds = "3600"
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
          guard let interval = Double(state.draftIntervalSeconds), interval > 0,
            !state.draftPrompt.isEmpty
          else { return .none }
          let prompt = state.draftPrompt
          state.showingNewNodeForm = false
          return .run { _ in
            try? await orchestratorClient.send(
              .graphCommand(
                projectPath: projectPath,
                command: .createTimeBasedNode(
                  title: title, intervalSeconds: interval, prompt: prompt)))
          }
        case .goalBased, .proactive:
          // Not creatable yet — see docs/07-roadmap.md's deferred goal-based/proactive
          // node config UI. The picker only offers turn-based/time-based.
          return .none
        }

      case .nodeTapped(let id):
        // Time-based nodes run headlessly in graphcoded; there's no local interactive
        // session for a human to open here (see docs/04-cli-backends.md).
        guard let node = state.graph.nodes[id: id],
          node.state != .blocked,
          node.loopType == .turnBased
        else { return .none }
        state.detail = LoopNodeDetailFeature.State(node: node)
        return .none

      case .detailDismissed:
        // No explicit teardown needed: `GhosttyTerminalNSView`'s `deinit` frees the
        // surface when the sheet's view hierarchy is torn down, which detaches from
        // the underlying `zmx` session (not kill it) the same way closing any other
        // terminal client to a persistent session does.
        state.detail = nil
        return .none

      case .closeProjectTapped:
        // Handled by `AppFeature`'s parent `Reduce`, which clears `state.project` —
        // nothing to do here.
        return .none

      case .edgeDrawn(let from, let to):
        guard from != to else { return .none }
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .createEdge(from: from, to: to)))
        }

      case .detail(.checkApproved):
        guard let id = state.detail?.node.id else { return .none }
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckApproved(id)))
        }

      case .detail(.checkRejected):
        guard let id = state.detail?.node.id else { return .none }
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .nodeCheckRejected(id)))
        }

      case .detail:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      LoopNodeDetailFeature()
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
