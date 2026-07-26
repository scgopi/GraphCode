import ComposableArchitecture
import Foundation

/// The Phase 2 root: a single project-scoped `LoopGraph`, edited by hand. See
/// docs/07-roadmap.md#phase-2--the-graph.
///
/// Manual only, on purpose — no automatic edge evaluation:
///   - Creating a node is always standalone (`.idle`, no inbound edges).
///   - Drawing an edge (`.edgeDrawn`) targets an *existing* node; if that node is still
///     `.idle`, it flips to `.blocked` — it now has an unfired inbound edge.
///   - `.edgeFireTapped` is the human "mark it fired" action. A node only comes back to
///     `.idle` once none of its inbound `.handoff` edges are unfired.
/// Automating any of this is Phase 3's job, once `graphcoded` exists to own it.
@Reducer
struct GraphCanvasFeature {
  @ObservableState
  struct State: Equatable {
    var graph: LoopGraph
    var nodePositions: [UUID: CGPoint] = [:]
    var detail: LoopNodeDetailFeature.State?
    var showingNewNodeForm = false
    var draftTitle = ""
    var draftCheck = ""

    init(graph: LoopGraph = LoopGraph(title: "My first graph")) {
      self.graph = graph
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case addNodeButtonTapped
    case createNodeConfirmed
    case cancelNewNodeForm
    case nodeTapped(UUID)
    case detailDismissed
    case edgeDrawn(from: UUID, to: UUID)
    case edgeFireTapped(UUID)
    case detail(LoopNodeDetailFeature.Action)
  }

  @Dependency(\.cliSessionClient) var cliSessionClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .addNodeButtonTapped:
        state.draftTitle = ""
        state.draftCheck = ""
        state.showingNewNodeForm = true
        return .none

      case .cancelNewNodeForm:
        state.showingNewNodeForm = false
        return .none

      case .createNodeConfirmed:
        guard !state.draftTitle.isEmpty, !state.draftCheck.isEmpty else { return .none }
        let node = LoopNode(title: state.draftTitle, checkDescription: state.draftCheck)
        state.graph.nodes.append(node)
        state.nodePositions[node.id] = Self.nextPosition(index: state.graph.nodes.count - 1)
        state.showingNewNodeForm = false
        return .none

      case .nodeTapped(let id):
        guard let node = state.graph.nodes[id: id], node.state != .blocked else { return .none }
        state.detail = LoopNodeDetailFeature.State(node: node)
        return .none

      case .detailDismissed:
        guard let detail = state.detail else { return .none }
        state.graph.nodes[id: detail.node.id] = detail.node
        let sessionID = detail.sessionID
        state.detail = nil
        guard let sessionID else { return .none }
        return .run { _ in await cliSessionClient.terminate(sessionID) }

      case .edgeDrawn(let from, let to):
        guard from != to,
          state.graph.nodes[id: from] != nil,
          state.graph.nodes[id: to] != nil,
          !state.graph.edges.contains(where: { $0.from == from && $0.to == to })
        else { return .none }

        state.graph.edges.append(LoopEdge(from: from, to: to))
        if state.graph.nodes[id: to]?.state == .idle {
          state.graph.nodes[id: to]?.state = .blocked
        }
        return .none

      case .edgeFireTapped(let edgeID):
        guard let edge = state.graph.edges[id: edgeID], !edge.fired else { return .none }
        state.graph.edges[id: edgeID]?.fired = true

        let targetID = edge.to
        let stillBlocked = state.graph.edges.contains {
          $0.to == targetID && $0.kind == .handoff && !$0.fired
        }
        if !stillBlocked, state.graph.nodes[id: targetID]?.state == .blocked {
          state.graph.nodes[id: targetID]?.state = .idle
        }
        return .none

      case .detail:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      LoopNodeDetailFeature()
    }
  }

  /// Simple grid layout for freshly created nodes — real layout (force-directed,
  /// draggable repositioning) is future work; Phase 2 just needs nodes to not overlap.
  private static func nextPosition(index: Int) -> CGPoint {
    let columns = 3
    let column = index % columns
    let row = index / columns
    return CGPoint(x: 160 + CGFloat(column) * 260, y: 140 + CGFloat(row) * 200)
  }
}
