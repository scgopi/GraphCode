import CoreGraphics
import GraphcodeKit

/// What a line on a canvas means. Two kinds, because they mean two different things and
/// drawing them alike would be a lie about how the graph runs:
///
/// - `.edge` is a real `LoopEdge` the daemon fires.
/// - `.containment` says a loop lives *inside* a composite's sub-graph.
///
/// There used to be a third, `.tether` — the lines from the start marker to each entry
/// point. The comments on it conceded what it was: not an edge, nothing travelling along
/// it, nothing to right-click. Project lane bands say the same "this belongs to that"
/// with position instead of ink, and the tether went with the marker.
enum GraphLinkKind: Equatable {
  case edge(EdgeKind, fired: Bool)
  case containment
}

/// One line, already resolved to two points in canvas coordinates. Shared by every
/// canvas so a tether, an edge, and a containment line are drawn identically wherever
/// they appear — see `EdgeLineView` and the canvases' own link layers.
struct CanvasLink: Identifiable, Equatable {
  let id: String
  let from: CGPoint
  let to: CGPoint
  let kind: GraphLinkKind
  /// A guarded back-edge's pass count — see `LoopEdge.cycleLabel`.
  var label: String?
}
