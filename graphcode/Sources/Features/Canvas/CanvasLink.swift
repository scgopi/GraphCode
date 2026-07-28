import CoreGraphics
import GraphcodeKit

/// What a line on a canvas means. Three kinds, because they mean three different things
/// and drawing them alike would be a lie about how the graph runs:
///
/// - `.tether` is structure — "this hangs off that". Nothing travels along it.
/// - `.edge` is a real `LoopEdge` the daemon fires.
/// - `.containment` says a loop lives *inside* a composite's sub-graph.
enum GraphLinkKind: Equatable {
  case tether
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
}
