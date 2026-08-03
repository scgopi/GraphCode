import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Drawing an edge: the connector handle you drag from, where a drop lands, and the
/// editor that opens on it — plus the two small lookups the cards read. Split out of
/// `ProjectCanvasView` purely for size, the same split `NodeDraftForm` got.
extension ProjectCanvasView {
  /// Shown on drop, before the edge is committed. The `?? pending` fallback in the
  /// binding never actually fires — the sheet only exists while `pendingEdge` is
  /// non-nil — it's just what lets a nested field bind without an optional dance.
  @ViewBuilder
  var edgeForm: some View {
    if let pending = store.pendingEdge {
      EdgeSpecForm(
        pending: Binding(
          get: { store.pendingEdge ?? pending },
          set: { store.pendingEdge = $0 }
        ),
        fromTitle: nodeTitle(pending.from),
        toTitle: nodeTitle(pending.to),
        onCancel: { store.send(.cancelEdgeForm) },
        onCreate: { store.send(.createEdgeConfirmed) }
      )
    }
  }

  func nodeTitle(_ id: UUID) -> String {
    store.canvasGraph.nodes[id: id]?.title ?? "?"
  }

  /// The + at a card's right-centre does double duty: a *click* creates a new loop
  /// already wired to this one (a hand-off edge from it — `.addChildNodeTapped`), a
  /// *drag* draws an edge to an existing node exactly as the plain dot always did. One
  /// element, because they're one idea — "continue the graph from here" — and two
  /// controls sharing a card edge would fight for the same 14 points.
  func connectorHandle(for nodeID: UUID) -> some View {
    CanvasConnectorHandle()
      .onTapGesture { store.send(.addChildNodeTapped(nodeID)) }
      .gesture(
        DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
          .onChanged { value in
            dragSourceID = nodeID
            dragLocation = value.location
          }
          .onEnded { value in
            if let targetID = hitTestNode(at: value.location, excluding: nodeID) {
              store.send(.edgeDrawn(from: nodeID, to: targetID))
            }
            dragSourceID = nil
            dragLocation = nil
          }
      )
  }

  /// Which node (if any) contains `point`, in "canvas"-space — approximate card frame,
  /// good enough for drop hit-testing without threading real card sizes through state.
  private func hitTestNode(at point: CGPoint, excluding: UUID) -> UUID? {
    for node in store.canvasGraph.nodes where node.id != excluding {
      guard let position = store.nodePositions[node.id] else { continue }
      let rect = CGRect(x: position.x - 110, y: position.y - 45, width: 220, height: 90)
      if rect.contains(point) { return node.id }
    }
    return nil
  }
}
