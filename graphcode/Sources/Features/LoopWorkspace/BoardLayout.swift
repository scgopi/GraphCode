import AppKit
import GraphcodeKit
import SwiftUI

/// Where every box and every arrow of a flow board goes — a layered graph layout, sized
/// against the text it is actually going to draw.
///
/// A value type with no view in it, for the reason `LoopSummaryPresentation` is one: the
/// layout is the part with the arithmetic, and arithmetic that can only be checked by
/// looking at a window is arithmetic nobody checks.
///
/// The method is the standard layered one, in three passes and no more, because a board is
/// capped at `SummaryBoard.maxNodes`:
///
/// 1. **Layer** — longest path from the roots, with cycles broken by depth-first ordering.
///    A flow that loops back on itself (`C -->|no| B`, the commonest shape a real run has)
///    would otherwise have no topological order at all.
/// 2. **Order** — declaration order, then two barycentre sweeps. Two rather than the usual
///    dozen: past that the crossings stop falling and the boxes only shuffle, and a diagram
///    that rearranges itself between two polls of the same run is worse than one with a
///    crossing in it.
/// 3. **Place** — each box centred over its parents, then a left-to-right sweep opening any
///    overlap the centring caused. Alignment is what makes a chain read as a chain; evenly
///    spacing every layer instead produces a correct diagram that looks like a grid.
struct BoardLayout: Equatable {
  struct PlacedNode: Equatable, Identifiable {
    let node: BoardNode
    let frame: CGRect
    var id: String { node.id }
  }

  struct PlacedEdge: Equatable, Identifiable {
    let edge: BoardEdge
    let start: CGPoint
    let end: CGPoint
    /// Where the arrow bends. Empty for the common case — one layer straight down.
    let waypoints: [CGPoint]
    let labelPoint: CGPoint
    /// An arrow going back up the flow: a retry, a rejected check, a loop. Routed around
    /// the outside rather than back through the boxes it would otherwise cross.
    let isFeedback: Bool
    /// How far this arrow is bowed off the straight line between its ends.
    ///
    /// Zero for all but one case: two arrows joining the *same pair* of boxes, which is
    /// what `C -->|yes| D` beside `C -->|no| D` produces. Drawn straight, they are one line
    /// with two labels stacked on the same point — the second is simply invisible.
    let spread: CGFloat
    /// Which way the arrow leaves and arrives — down the board or across it.
    ///
    /// Carried rather than inferred from the two ends, because it is a fact about how the
    /// curve is *drawn* and not about where it goes. The control points are offset along
    /// this axis, so an arrow whose ends are further apart sideways than downwards still
    /// enters its box from above; a head that took its direction from the chord pointed
    /// sideways into the top of the box, which is what it did until this was stored.
    let axis: BoardDirection
    var id: String { edge.id }

    func offset(by delta: CGPoint) -> PlacedEdge {
      func moved(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + delta.x, y: point.y + delta.y)
      }
      return PlacedEdge(
        edge: edge, start: moved(start), end: moved(end),
        waypoints: waypoints.map(moved), labelPoint: moved(labelPoint),
        isFeedback: isFeedback, spread: spread, axis: axis)
    }
  }

  let nodes: [PlacedNode]
  let edges: [PlacedEdge]
  let size: CGSize

  static let empty = BoardLayout(nodes: [], edges: [], size: .zero)

  // MARK: - Metrics

  /// Where a label stops growing sideways and starts wrapping. Six words at 11.5pt is
  /// around here, which is the budget the composer's prompt hands the model.
  static let maxLabelWidth: CGFloat = 132
  static let horizontalPadding: CGFloat = 11
  static let verticalPadding: CGFloat = 7
  static let minimumNodeWidth: CGFloat = 58
  static let minimumNodeHeight: CGFloat = 28
  /// Between layers. Enough for an edge label to sit in without touching either box.
  static let layerGap: CGFloat = 34
  static let siblingGap: CGFloat = 16
  /// How far outside the widest box a feedback arrow climbs.
  static let feedbackInset: CGFloat = 18
  static let labelFont = NSFont.systemFont(ofSize: 11.5)
  /// What `SummaryBoardView` draws an edge label in. Kept here because the *size* is
  /// needed here — an arrow label sitting on the outermost lane extends past the last box,
  /// and a drawing measured without it is a drawing with its own label clipped off.
  static let edgeLabelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
  /// The chip's padding around that text, as the view draws it.
  static let edgeLabelPadding = CGSize(width: 4, height: 2)

  static func edgeLabelSize(_ text: String) -> CGSize {
    let bounds = (text as NSString).size(withAttributes: [.font: edgeLabelFont])
    return CGSize(
      width: ceil(bounds.width) + edgeLabelPadding.width * 2,
      height: ceil(bounds.height) + edgeLabelPadding.height * 2)
  }

  /// A diamond wastes its corners: text laid out inside one needs about half as much again
  /// in each direction before it stops touching the edges.
  static let decisionScale: CGFloat = 1.45

  static func labelSize(_ text: String) -> CGSize {
    let bounds = (text as NSString).boundingRect(
      with: CGSize(width: maxLabelWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: labelFont])
    return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
  }

  static func nodeSize(_ node: BoardNode) -> CGSize {
    let label = labelSize(node.text)
    var width = label.width + horizontalPadding * 2
    var height = label.height + verticalPadding * 2
    if node.shape == .decision {
      width *= decisionScale
      height *= decisionScale
    }
    return CGSize(width: max(width, minimumNodeWidth), height: max(height, minimumNodeHeight))
  }

  // MARK: - Building

  init(nodes: [PlacedNode], edges: [PlacedEdge], size: CGSize) {
    self.nodes = nodes
    self.edges = edges
    self.size = size
  }

  init(board: SummaryBoard) {
    guard board.form == .flow, board.nodes.count >= 2 else {
      self = .empty
      return
    }
    let identifiers = board.nodes.map(\.id)
    let index = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($1, $0) })
    let feedback = Self.feedbackEdges(board: board, order: identifiers)
    let forward = board.edges.filter { !feedback.contains($0.id) }
    let layers = Self.layers(of: identifiers, edges: forward)
    let rows = Self.ordered(identifiers: identifiers, layers: layers, edges: forward, index: index)

    let sizes = Dictionary(
      uniqueKeysWithValues: board.nodes.map { ($0.id, Self.nodeSize($0)) })
    let frames = Self.place(
      rows: rows, sizes: sizes, edges: forward, direction: board.direction)

    let placed = board.nodes.compactMap { node in
      frames[node.id].map { PlacedNode(node: node, frame: $0) }
    }
    let bounds = placed.reduce(CGRect.null) { $0.union($1.frame) }
    guard !bounds.isNull else {
      self = .empty
      return
    }
    // Shifted so the drawing starts at the origin. A layout that began at negative
    // coordinates would be clipped by the frame it is drawn in rather than by anything it
    // chose.
    let offset = CGPoint(x: -bounds.minX, y: -bounds.minY)
    let shifted = placed.map {
      PlacedNode(node: $0.node, frame: $0.frame.offsetBy(dx: offset.x, dy: offset.y))
    }
    let routed = Self.routes(
      of: board, frames: Dictionary(uniqueKeysWithValues: shifted.map { ($0.id, $0.frame) }),
      feedback: feedback,
      // Outside the widest box, on the side a feedback arrow climbs.
      lane: bounds.width + Self.feedbackInset)
    let drawn = Self.drawnBounds(nodes: shifted, edges: routed)
    let correction = CGPoint(x: -min(drawn.minX, 0), y: -min(drawn.minY, 0))
    self.init(
      nodes: shifted.map {
        PlacedNode(node: $0.node, frame: $0.frame.offsetBy(dx: correction.x, dy: correction.y))
      },
      edges: routed.map { $0.offset(by: correction) },
      size: CGSize(width: drawn.maxX + correction.x, height: drawn.maxY + correction.y))
  }

  /// How far each arrow is bowed aside, so two arrows between the same pair of boxes do not
  /// land on top of one another. Zero for every edge that has the pair to itself, which is
  /// nearly all of them.
  static func spreads(of edges: [BoardEdge]) -> [String: CGFloat] {
    var groups: [String: [BoardEdge]] = [:]
    for edge in edges { groups["\(edge.from)→\(edge.to)", default: []].append(edge) }
    var result: [String: CGFloat] = [:]
    for (_, group) in groups where group.count > 1 {
      for (offset, edge) in group.enumerated() {
        result[edge.id] = (CGFloat(offset) - CGFloat(group.count - 1) / 2) * parallelSpread
      }
    }
    return result
  }

  /// Far enough apart that two labels on the same pair of boxes both fit between them.
  static let parallelSpread: CGFloat = 34

  /// Everything the drawing occupies — **the arrows included, not only the boxes**.
  ///
  /// A feedback arrow leaves the bottom of the last row and climbs a lane outside the widest
  /// one, and an edge label on that lane reaches further still. A size taken from the node
  /// frames alone reports a drawing smaller than the one being drawn, and the parts outside
  /// it are silently clipped by the panel.
  static func drawnBounds(nodes: [PlacedNode], edges: [PlacedEdge]) -> CGRect {
    var drawn = nodes.reduce(CGRect.null) { $0.union($1.frame) }
    for edge in edges {
      for point in [edge.start, edge.end] + edge.waypoints {
        drawn = drawn.union(CGRect(origin: point, size: .zero).insetBy(dx: -1, dy: -1))
      }
      guard let label = edge.edge.label, !label.isEmpty else { continue }
      let size = edgeLabelSize(label)
      drawn = drawn.union(
        CGRect(
          x: edge.labelPoint.x - size.width / 2, y: edge.labelPoint.y - size.height / 2,
          width: size.width, height: size.height))
    }
    return drawn
  }
}
