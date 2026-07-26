import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The app's root feature: a mirror of `graphcoded`'s one `LoopGraph`, plus purely
/// local UI state (canvas layout, the new-node form). See
/// docs/07-roadmap.md#phase-3--orchestrator-automation.
///
/// From Phase 3 on this does **not** own graph state — `graphcoded` does.
/// Node/edge-creation and check-resolution actions send a `DaemonCommand` and wait for
/// the resulting `.graphChanged` broadcast rather than mutating `state.graph` directly;
/// automatic `.handoff` firing happens in the daemon, not here (see
/// `graphcoded/Sources/GraphStore.swift`). `nodePositions` stays local — canvas layout
/// is a UI concern the daemon has no reason to know about.
@Reducer
struct GraphCanvasFeature {
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

    init(graph: LoopGraph = LoopGraph(title: "My first graph")) {
      self.graph = graph
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case task
    case daemonEvent(DaemonEvent)
    case addNodeButtonTapped
    case createNodeConfirmed
    case cancelNewNodeForm
    case nodeTapped(UUID)
    case detailDismissed
    case edgeDrawn(from: UUID, to: UUID)
    case detail(LoopNodeDetailFeature.Action)
  }

  private enum CancelID { case daemonSubscription }

  @Dependency(\.cliSessionClient) var cliSessionClient
  @Dependency(\.orchestratorClient) var orchestratorClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .task:
        return .run { send in
          for await event in orchestratorClient.connect() {
            await send(.daemonEvent(event))
          }
        }
        .cancellable(id: CancelID.daemonSubscription)

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
        let title = state.draftTitle
        switch state.draftLoopType {
        case .turnBased:
          guard !state.draftCheck.isEmpty else { return .none }
          let checkDescription = state.draftCheck
          state.showingNewNodeForm = false
          return .run { _ in
            try? await orchestratorClient.send(
              .createTurnBasedNode(title: title, checkDescription: checkDescription))
          }
        case .timeBased:
          guard let interval = Double(state.draftIntervalSeconds), interval > 0,
            !state.draftPrompt.isEmpty
          else { return .none }
          let prompt = state.draftPrompt
          state.showingNewNodeForm = false
          return .run { _ in
            try? await orchestratorClient.send(
              .createTimeBasedNode(title: title, intervalSeconds: interval, prompt: prompt))
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
        guard let detail = state.detail else { return .none }
        let sessionID = detail.sessionID
        state.detail = nil
        guard let sessionID else { return .none }
        return .run { _ in await cliSessionClient.terminate(sessionID) }

      case .edgeDrawn(let from, let to):
        guard from != to else { return .none }
        return .run { _ in
          try? await orchestratorClient.send(.createEdge(from: from, to: to))
        }

      case .detail(.checkApproved):
        guard let id = state.detail?.node.id else { return .none }
        return .run { _ in try? await orchestratorClient.send(.nodeCheckApproved(id)) }

      case .detail(.checkRejected):
        guard let id = state.detail?.node.id else { return .none }
        return .run { _ in try? await orchestratorClient.send(.nodeCheckRejected(id)) }

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
