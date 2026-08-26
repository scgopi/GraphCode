import AppKit
import GraphcodeKit
import SwiftUI

/// How a board's arrows get from box to box — the second half of `BoardLayout`, kept in its
/// own file because the placement above it and the routing here answer different questions
/// and neither is short.
///
/// Two kinds of arrow, and the difference is the whole of it. A forward arrow leaves the
/// bottom of one box and enters the top of the next, and can be a single curve. A feedback
/// arrow — a retry, a rejected check — has to travel back up past everything between its
/// two ends, which means going round the outside through the bands the layout leaves empty.
extension BoardLayout {
  // MARK: - Routing

  /// Everything a route needs to know that is the same for every arrow on the board.
  ///
  /// A struct rather than six parameters: the frames, the direction and the lane are one
  /// fact about one layout, and passing them individually to a function called once per
  /// edge made the signature longer than the routing.
  struct RouteContext {
    let frames: [String: CGRect]
    let direction: BoardDirection
    /// Which edges have to travel back up the board — see `feedbackEdges`.
    let feedback: Set<String>
    /// How far each arrow is bowed aside, so two arrows between the same pair of boxes do
    /// not land on top of one another.
    let spreads: [String: CGFloat]
    /// Where a feedback arrow climbs, outside the widest box.
    let lane: CGFloat
  }

  static func routes(
    of board: SummaryBoard, frames: [String: CGRect], feedback: Set<String>, lane: CGFloat
  ) -> [PlacedEdge] {
    let context = RouteContext(
      frames: frames, direction: board.direction, feedback: feedback,
      spreads: spreads(of: board.edges), lane: lane)
    return board.edges.compactMap { route($0, in: context) }
  }

  static func route(_ edge: BoardEdge, in context: RouteContext) -> PlacedEdge? {
    guard let from = context.frames[edge.from], let to = context.frames[edge.to] else {
      return nil
    }
    if context.feedback.contains(edge.id) {
      return feedbackRoute(edge, from: from, to: to, lane: context.lane)
    }
    let spread = context.spreads[edge.id] ?? 0
    let start: CGPoint
    let end: CGPoint
    switch context.direction {
    case .topDown:
      start = CGPoint(x: from.midX, y: from.maxY)
      end = CGPoint(x: to.midX, y: to.minY)
    case .leftRight:
      start = CGPoint(x: from.maxX, y: from.midY)
      end = CGPoint(x: to.minX, y: to.midY)
    }
    // The bow is across the direction of travel, so a pair of arrows separates sideways on
    // a top-down board and vertically on a left-right one.
    let nudge =
      context.direction == .topDown
      ? CGPoint(x: spread, y: 0) : CGPoint(x: 0, y: spread)
    return PlacedEdge(
      edge: edge, start: start, end: end, waypoints: [],
      labelPoint: CGPoint(
        x: (start.x + end.x) / 2 + nudge.x, y: (start.y + end.y) / 2 + nudge.y),
      isFeedback: false, spread: spread, axis: context.direction)
  }

  /// An arrow climbing back up the flow, routed through the empty bands between layers.
  ///
  /// **Out of the bottom and in at the top, never out of the side.** The first version left
  /// the source box on its right and re-entered the target on *its* right, at each box's own
  /// mid-height — which is the height of every other box in that row, so the horizontal run
  /// went straight through its neighbours. The boxes draw over the arrows, so the result was
  /// not even a visible mistake: the retry arrow simply vanished behind the box beside it,
  /// and a diagram whose whole point was the loop appeared to have none.
  ///
  /// The bands half a `layerGap` below one row and above another hold no boxes by
  /// construction, which makes them the one place a horizontal run is always safe.
  static func feedbackRoute(
    _ edge: BoardEdge, from: CGRect, to: CGRect, lane: CGFloat
  ) -> PlacedEdge {
    let below = from.maxY + layerGap / 2
    let above = to.minY - layerGap / 2
    return PlacedEdge(
      edge: edge,
      start: CGPoint(x: from.midX, y: from.maxY),
      end: CGPoint(x: to.midX, y: to.minY),
      waypoints: [
        CGPoint(x: from.midX, y: below),
        CGPoint(x: lane, y: below),
        CGPoint(x: lane, y: above),
        CGPoint(x: to.midX, y: above),
      ],
      labelPoint: CGPoint(x: lane, y: (below + above) / 2),
      // Down into the target's top, whichever way the board itself runs: the last leg of a
      // feedback route is always the drop out of the band above its target.
      isFeedback: true, spread: 0, axis: .topDown)
  }
}
