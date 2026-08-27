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
    /// Every box on the board, so a route can tell whether it would cross one.
    let boxes: [String: CGRect]
    /// The lane assigned to each arrow that has to go round a box in its way — see
    /// `detourLanes`.
    let detours: [String: DetourLane]
  }

  /// Where one detour runs, and which detour it is.
  ///
  /// The index is carried because two lanes twenty points apart still put their labels on
  /// top of one another — a label is wider than the gap. Each detour hangs its label at a
  /// different height along its own lane instead.
  struct DetourLane: Equatable {
    let lane: CGFloat
    let index: Int
  }

  static func routes(
    of board: SummaryBoard, frames: [String: CGRect], feedback: Set<String>, lane: CGFloat
  ) -> [PlacedEdge] {
    let context = RouteContext(
      frames: frames, direction: board.direction, feedback: feedback,
      spreads: spreads(of: board.edges), lane: lane, boxes: frames,
      detours: detourLanes(
        of: board, frames: frames, feedback: feedback,
        direction: board.direction))
    return board.edges.compactMap { route($0, in: context) }
  }

  /// Which arrows cannot be drawn straight, and where each one goes instead.
  ///
  /// **An arrow that skips a layer crosses whatever sits in the layer it skipped.** A
  /// `C -->|no| F` beside a `C --> E --> F` leaves C's bottom and enters F's top, straight
  /// through E — and since the boxes are drawn *over* the arrows, the line does not merely
  /// cross E, it disappears behind it, taking its `no` label with it. A diagram that showed
  /// a branch then showed one arm of it and no sign of the other.
  ///
  /// Each blocked arrow gets its own lane outside the drawing, on the opposite side from
  /// the feedback lane, so a board with both keeps them apart and two detours do not land
  /// on one line.
  static func detourLanes(
    of board: SummaryBoard, frames: [String: CGRect], feedback: Set<String>,
    direction: BoardDirection
  ) -> [String: DetourLane] {
    var lanes: [String: DetourLane] = [:]
    var taken = 0
    for edge in board.edges
    where !feedback.contains(edge.id) && edge.from != edge.to {
      guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
      let start: CGPoint
      let end: CGPoint
      switch direction {
      case .topDown:
        start = CGPoint(x: from.midX, y: from.maxY)
        end = CGPoint(x: to.midX, y: to.minY)
      case .leftRight:
        start = CGPoint(x: from.maxX, y: from.midY)
        end = CGPoint(x: to.minX, y: to.midY)
      }
      let blocked = frames.contains { id, box in
        id != edge.from && id != edge.to
          && segment(from: start, to: end, crosses: box.insetBy(dx: 2, dy: 2))
      }
      guard blocked else { continue }
      lanes[edge.id] = DetourLane(
        lane: -(feedbackInset + CGFloat(taken) * detourLaneGap), index: taken)
      taken += 1
    }
    return lanes
  }

  /// How far apart two detour lanes sit — an edge label's height, so two labelled detours
  /// do not stack their chips on one another.
  static let detourLaneGap: CGFloat = 20

  /// Whether a straight run between two points passes through a box. Liang–Barsky, because
  /// sampling the line misses a box narrower than the sample step and this has to be right
  /// about the one case it exists for.
  static func segment(from start: CGPoint, to end: CGPoint, crosses box: CGRect) -> Bool {
    guard !box.isEmpty else { return false }
    let dx = end.x - start.x
    let dy = end.y - start.y
    var enter: CGFloat = 0
    var exit: CGFloat = 1
    let checks: [(p: CGFloat, q: CGFloat)] = [
      (-dx, start.x - box.minX), (dx, box.maxX - start.x),
      (-dy, start.y - box.minY), (dy, box.maxY - start.y),
    ]
    for check in checks {
      if check.p == 0 {
        if check.q < 0 { return false }
        continue
      }
      let ratio = check.q / check.p
      if check.p < 0 {
        enter = max(enter, ratio)
      } else {
        exit = min(exit, ratio)
      }
      if enter > exit { return false }
    }
    return true
  }

  static func route(_ edge: BoardEdge, in context: RouteContext) -> PlacedEdge? {
    guard let from = context.frames[edge.from], let to = context.frames[edge.to] else {
      return nil
    }
    if edge.from == edge.to {
      return selfRoute(edge, box: from)
    }
    if context.feedback.contains(edge.id) {
      return feedbackRoute(edge, from: from, to: to, lane: context.lane)
    }
    if let detour = context.detours[edge.id] {
      return bandRoute(edge, from: from, to: to, detour: detour, axis: context.direction)
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

  /// A forward arrow taken out of the boxes' way — out of its source, across the empty band
  /// under it, along a lane outside the drawing, and back in through the band above its
  /// target.
  ///
  /// The same three-band shape as `feedbackRoute` and, unlike it, written for both
  /// directions: a left-right board's empty bands run down the page rather than across it,
  /// and a detour that assumed otherwise would step aside into the boxes it was avoiding.
  static func bandRoute(
    _ edge: BoardEdge, from: CGRect, to: CGRect, detour: DetourLane, axis: BoardDirection
  ) -> PlacedEdge {
    let lane = detour.lane
    // Alternating heights along the lane, so two detours running past each other do not
    // stack their labels on one point.
    let along: CGFloat = detour.index.isMultiple(of: 2) ? 0.36 : 0.68
    switch axis {
    case .topDown:
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
        labelPoint: CGPoint(x: lane, y: below + (above - below) * along),
        isFeedback: false, spread: 0, axis: .topDown)
    case .leftRight:
      let after = from.maxX + layerGap / 2
      let before = to.minX - layerGap / 2
      return PlacedEdge(
        edge: edge,
        start: CGPoint(x: from.maxX, y: from.midY),
        end: CGPoint(x: to.minX, y: to.midY),
        waypoints: [
          CGPoint(x: after, y: from.midY),
          CGPoint(x: after, y: lane),
          CGPoint(x: before, y: lane),
          CGPoint(x: before, y: to.midY),
        ],
        labelPoint: CGPoint(x: after + (before - after) * along, y: lane),
        isFeedback: false, spread: 0, axis: .leftRight)
    }
  }

  /// `A --> A` — a step that repeats itself.
  ///
  /// It has always parsed and it has never been drawn: a self-edge is a cycle, so the
  /// feedback pass claimed it, and `feedbackRoute` then drew it out to the same lane every
  /// other feedback arrow uses, where it landed on top of one of them and read as nothing
  /// at all. It gets a loop of its own instead, hugging the box it belongs to, which is
  /// what a self-edge means and where a reader looks for it.
  static func selfRoute(_ edge: BoardEdge, box: CGRect) -> PlacedEdge {
    let lane = box.maxX + selfLoopReach
    let above = box.minY - selfLoopRise
    let entry = CGPoint(x: box.midX + box.width / 4, y: box.minY)
    return PlacedEdge(
      edge: edge,
      start: CGPoint(x: box.maxX, y: box.midY),
      end: entry,
      waypoints: [
        CGPoint(x: lane, y: box.midY),
        CGPoint(x: lane, y: above),
        CGPoint(x: entry.x, y: above),
      ],
      labelPoint: CGPoint(x: lane + selfLoopReach, y: (above + box.midY) / 2),
      isFeedback: true, spread: 0, axis: .topDown)
  }

  /// How far outside its box a self-loop reaches, and how far above it climbs. Both small:
  /// the loop is a mark on one box, not a journey across the board.
  static let selfLoopReach: CGFloat = 14
  static let selfLoopRise: CGFloat = 16
}
