import AppKit
import GraphcodeKit
import SwiftUI

/// Which layer each box belongs to, what order they sit in across it, and where that puts
/// them — the first three passes of `BoardLayout`, kept apart from the routing that follows
/// them and the type that hands both a board.
///
/// All of it works in two abstract coordinates, *along* the flow and *across* it, and only
/// turns them into rectangles at the end. That is what lets one routine lay out `TD` and
/// `LR` boards correctly rather than laying out one and transposing it — see `place`, which
/// records what transposing got wrong.
extension BoardLayout {
  // MARK: - Cycles

  /// The edges that have to be ignored for the graph to have layers at all.
  ///
  /// Found by depth-first search from the declaration order: an edge reaching a node still
  /// on the stack is the one closing the cycle. Declaration order rather than an arbitrary
  /// start, so the arrow the *author* wrote as the loop-back — which in Mermaid is almost
  /// always the retry — is the one that gets drawn as one.
  static func feedbackEdges(board: SummaryBoard, order: [String]) -> Set<String> {
    var outgoing: [String: [BoardEdge]] = [:]
    for edge in board.edges { outgoing[edge.from, default: []].append(edge) }
    var feedback: Set<String> = []
    var state: [String: Int] = [:]  // 0 unvisited, 1 on stack, 2 done

    func visit(_ id: String) {
      state[id] = 1
      for edge in outgoing[id] ?? [] {
        switch state[edge.to] ?? 0 {
        case 1: feedback.insert(edge.id)
        case 0: visit(edge.to)
        default: break
        }
      }
      state[id] = 2
    }
    for id in order where (state[id] ?? 0) == 0 { visit(id) }
    return feedback
  }

  // MARK: - Layering

  /// Longest path: a box sits one layer below the lowest thing pointing at it, so a step
  /// with two prerequisites is drawn under both of them rather than beside one.
  static func layers(of identifiers: [String], edges: [BoardEdge]) -> [String: Int] {
    var incoming: [String: [String]] = [:]
    for edge in edges { incoming[edge.to, default: []].append(edge.from) }
    var layers: [String: Int] = [:]

    func depth(_ id: String, _ seen: Set<String>) -> Int {
      if let known = layers[id] { return known }
      // `seen` is belt and braces: the feedback pass has already made this acyclic, and a
      // recursion that trusted that and was wrong would not return.
      guard !seen.contains(id) else { return 0 }
      let above = (incoming[id] ?? []).map { depth($0, seen.union([id])) }
      let value = above.isEmpty ? 0 : (above.max() ?? 0) + 1
      layers[id] = value
      return value
    }
    for id in identifiers { _ = depth(id, []) }
    return layers
  }

  /// Which boxes share a layer, in the order they should be drawn across it.
  static func ordered(
    identifiers: [String], layers: [String: Int], edges: [BoardEdge], index: [String: Int]
  ) -> [[String]] {
    let depth = (layers.values.max() ?? 0) + 1
    var rows: [[String]] = Array(repeating: [], count: depth)
    for id in identifiers { rows[layers[id] ?? 0].append(id) }

    var parents: [String: [String]] = [:]
    for edge in edges { parents[edge.to, default: []].append(edge.from) }

    for _ in 0..<2 {
      var position: [String: Double] = [:]
      for row in rows {
        for (offset, id) in row.enumerated() { position[id] = Double(offset) }
      }
      for level in 1..<max(depth, 1) {
        rows[level].sort { left, right in
          let first = Self.barycentre(left, parents: parents, position: position, index: index)
          let second = Self.barycentre(right, parents: parents, position: position, index: index)
          if first != second { return first < second }
          // Declaration order breaks every tie, so the layout is a pure function of the
          // Mermaid and two polls of an unchanged board draw the same picture.
          return (index[left] ?? 0) < (index[right] ?? 0)
        }
      }
    }
    return rows
  }

  static func barycentre(
    _ id: String, parents: [String: [String]], position: [String: Double], index: [String: Int]
  ) -> Double {
    let above = (parents[id] ?? []).compactMap { position[$0] }
    guard !above.isEmpty else { return Double(index[id] ?? 0) }
    return above.reduce(0, +) / Double(above.count)
  }

  // MARK: - Placement

  /// One box's claim on its row, before the sweep that opens any overlap between claims.
  struct Slot {
    let id: String
    let centre: CGFloat
    let extent: CGFloat
  }

  /// How far one row reaches across the board, for the centring pass.
  struct Span {
    let row: [String]
    let low: CGFloat
    let high: CGFloat
  }

  /// Boxes into rows, in the two coordinates a layered layout actually has: *along* the
  /// flow, which is one row per layer, and *across* it, which is where a box sits within
  /// its row.
  ///
  /// **Axis-aware rather than laid out downwards and turned.** The first version placed
  /// everything top-down and transposed the rectangles for `LR`, which is wrong in a way
  /// that is invisible until you draw it: the spacing between layers is worked out from the
  /// extent along the layer axis — heights, going down — and after a transpose that axis
  /// carries the *widths*. Rows 62 points apart then held boxes 130 points wide, and every
  /// box in an `LR` board landed on top of the one before it.
  static func place(
    rows: [[String]], sizes: [String: CGSize], edges: [BoardEdge], direction: BoardDirection
  ) -> [String: CGRect] {
    let vertical = direction == .topDown
    func along(_ size: CGSize) -> CGFloat { vertical ? size.height : size.width }
    func across(_ size: CGSize) -> CGFloat { vertical ? size.width : size.height }
    func centreAcross(_ frame: CGRect) -> CGFloat { vertical ? frame.midX : frame.midY }

    var parents: [String: [String]] = [:]
    for edge in edges { parents[edge.to, default: []].append(edge.from) }

    var frames: [String: CGRect] = [:]
    var depth: CGFloat = 0
    for row in rows {
      let rowDepth = row.compactMap { sizes[$0].map(along) }.max() ?? minimumNodeHeight
      // Each box wants to sit where its parents' centres say it belongs, and the sweep
      // below opens whatever that collides with. A first row, or one whose parents are all
      // unplaced, falls back to laying out from zero and is centred at the end.
      var wanted: [Slot] = []
      var cursor: CGFloat = 0
      for id in row {
        let size = sizes[id] ?? CGSize(width: minimumNodeWidth, height: minimumNodeHeight)
        let above = (parents[id] ?? []).compactMap { frames[$0].map(centreAcross) }
        let centre =
          above.isEmpty
          ? cursor + across(size) / 2 : above.reduce(0, +) / CGFloat(above.count)
        wanted.append(Slot(id: id, centre: centre, extent: across(size)))
        cursor += across(size) + siblingGap
      }
      var minimum = -CGFloat.greatestFiniteMagnitude
      for entry in wanted {
        let size = sizes[entry.id] ?? CGSize(width: minimumNodeWidth, height: minimumNodeHeight)
        let centre = max(entry.centre, minimum + entry.extent / 2)
        // Centred within its row on the along-axis too, so a short box beside a tall one
        // has its arrows meet at the same height.
        let offset = depth + (rowDepth - along(size)) / 2
        frames[entry.id] =
          vertical
          ? CGRect(
            x: centre - size.width / 2, y: offset, width: size.width, height: size.height)
          : CGRect(
            x: offset, y: centre - size.height / 2, width: size.width, height: size.height)
        minimum = centre + entry.extent / 2 + siblingGap
      }
      depth += rowDepth + layerGap
    }
    return centredRows(frames, rows: rows, direction: direction)
  }

  /// Every row centred on the widest one. The sweep above only ever pushes boxes one way,
  /// so without this a layout drifts steadily sideways as it descends.
  static func centredRows(
    _ frames: [String: CGRect], rows: [[String]], direction: BoardDirection
  ) -> [String: CGRect] {
    let vertical = direction == .topDown
    func low(_ frame: CGRect) -> CGFloat { vertical ? frame.minX : frame.minY }
    func high(_ frame: CGRect) -> CGFloat { vertical ? frame.maxX : frame.maxY }

    let spans = rows.compactMap { row -> Span? in
      let boxes = row.compactMap { frames[$0] }
      guard let first = boxes.map(low).min(), let last = boxes.map(high).max() else {
        return nil
      }
      return Span(row: row, low: first, high: last)
    }
    guard let widest = spans.map({ $0.high - $0.low }).max(), widest > 0 else { return frames }
    var result = frames
    for span in spans {
      let shift = (widest - (span.high - span.low)) / 2 - span.low
      for id in span.row {
        guard let frame = result[id] else { continue }
        result[id] = frame.offsetBy(
          dx: vertical ? shift : 0, dy: vertical ? 0 : shift)
      }
    }
    return result
  }

}
