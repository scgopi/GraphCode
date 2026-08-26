import CoreGraphics
import Foundation
import GraphcodeKit

/// Where one graph's cards go: the column says how far a loop sits from a beginning, the
/// row says which chain it belongs to.
///
/// Lifted out of the Graph view's lane layout so a folder's own canvas can be placed by the
/// same rules. The two used to disagree about what a graph looks like — the Graph view read
/// the edges and laid chains out left-to-right off a column of beginnings, while a project's
/// canvas handed out grid slots in whatever order nodes arrived from the daemon and never
/// looked at an edge at all. The same three loops therefore read as a chain in one view and
/// as a scatter in the other, with the hand-offs between them running behind the cards.
/// There is one answer to "where does this card go" now, and both canvases ask it.
///
/// Positions are *derived*, never accumulated. Recomputing from the graph is cheaper than
/// reconciling a stored table against the next broadcast, and it is the whole point: a new
/// edge has to re-flow the cards it now relates, which a table of slots handed out at
/// arrival time can never do.
struct LaneLayout: Equatable {
  /// One card's place in the lane, before it becomes a point.
  struct Slot: Hashable {
    let column: Int
    let row: Int
  }

  enum Metrics {
    static let card = LoopCardView.Metrics.size
    static let columnGap: CGFloat = 40
    static let rowGap: CGFloat = 24
    /// How far right a chain runs before it folds back into the last column. A lane that
    /// grew without bound would push whatever is below it off the canvas, and four
    /// hand-offs is already deeper than a real graph goes.
    static let columns = 4

    static let columnWidth = card.width + columnGap
    static let rowHeight = card.height + rowGap
    /// Where a lane's band begins. On the Graph view that leaves the start node its own
    /// 60pt column plus a gap; a project's canvas has no start node, but it keeps the
    /// margin so a band drawn around its cards lands exactly where a lane's band does.
    static let bandX: CGFloat = 80
    /// Clear of the attention rail, which floats over both canvases' top-left corner.
    static let laneTop: CGFloat = 62
    static let bandWidth =
      CanvasBand.padding * 2 + CanvasBand.originLane + CGFloat(columns) * card.width
      + CGFloat(columns - 1) * columnGap
    /// The first card's centre, inside the band and clear of the origin lane.
    static let firstLoopX =
      bandX + CanvasBand.padding + CanvasBand.originLane + card.width / 2
    static let firstRowInset = CanvasBand.captionHeight + CanvasBand.padding + card.height / 2
    /// The first card's centre on a canvas showing exactly one graph. The Graph view
    /// stacks several, so it offsets each lane's own top instead — see `GraphOverview`.
    static let origin = CGPoint(x: firstLoopX, y: laneTop + firstRowInset)
  }

  /// Which column and row each node landed in.
  private(set) var slots: [UUID: Slot] = [:]
  /// Each node's card centre, in canvas coordinates.
  private(set) var positions: [UUID: CGPoint] = [:]
  /// How many rows the lane used — never zero, so a band around an empty graph is still
  /// one row tall rather than a caption-height sliver.
  private(set) var rowCount = 1

  /// - Parameters:
  ///   - roles: passed in rather than resolved here because both callers already have
  ///     them for their cards, and `CardEntryRole.roles(in:)` walks the whole edge list.
  ///   - rowHeight: the Graph view's pitch unless the caller needs a taller one — see
  ///     `rowHeight(for:)`.
  init(
    graph: LoopGraph, roles: [UUID: CardEntryRole], origin: CGPoint = Metrics.origin,
    rowHeight: CGFloat = Metrics.rowHeight
  ) {
    // Everything nothing hands off to goes in column 0, one per row, and each chain flows
    // right along its own row.
    //
    // Filling rows left-to-right put all four rootless cards of a real graph side by side,
    // which hid the origin's fan behind them — cards draw over the lines, so the connectors
    // showed only in the gaps and read as one card chained to the next. A column of
    // beginnings is also how the graph reads: down the left is where work starts, across is
    // where it goes.
    let hangsOffOrigin: (LoopNode) -> Bool = {
      roles[$0.id] == .entry || roles[$0.id] == .unwired
    }
    let starts = Array(graph.nodes).filter(hangsOffOrigin)
    let depths = Self.depths(in: graph, from: starts.map(\.id))

    var placed: [UUID: Slot] = [:]
    var takenRows: Set<Int> = []
    var occupied: Set<Slot> = []

    func place(_ node: LoopNode, preferring row: Int) {
      guard placed[node.id] == nil else { return }
      let column = min(depths[node.id] ?? 0, Metrics.columns - 1)
      var candidate = row
      while occupied.contains(Slot(column: column, row: candidate)) { candidate += 1 }
      let slot = Slot(column: column, row: candidate)
      placed[node.id] = slot
      occupied.insert(slot)
      takenRows.insert(candidate)
      // Walk this chain onward on the same row, so a hand-off reads as one line of work.
      for edge in graph.edges where edge.from == node.id {
        guard let next = graph.nodes[id: edge.to] else { continue }
        place(next, preferring: candidate)
      }
    }

    var nextRow = 0
    for node in starts {
      while takenRows.contains(nextRow) { nextRow += 1 }
      place(node, preferring: nextRow)
    }
    // Whatever a walk from a beginning never reached: a closed cycle, which has none.
    for node in graph.nodes where placed[node.id] == nil {
      while takenRows.contains(nextRow) { nextRow += 1 }
      place(node, preferring: nextRow)
    }

    slots = placed
    positions = placed.mapValues { slot in
      CGPoint(
        x: origin.x + CGFloat(slot.column) * Metrics.columnWidth,
        y: origin.y + CGFloat(slot.row) * rowHeight)
    }
    rowCount = max((placed.values.map(\.row).max() ?? 0) + 1, 1)
  }

  /// Every card one canvas can show: this graph's own loops, plus the insides of every
  /// composite on it.
  ///
  /// Drilling into a composite swaps the canvas over to its sub-graph (see
  /// `ProjectFeature.State.canvasGraph`), and those loops need somewhere to be too — a
  /// missing position draws every card of a drilled-in canvas at the same unplaced point.
  /// Node ids are unique across the whole tree, so one flat table serves every level; the
  /// levels are laid out over each other on purpose, since exactly one of them is ever on
  /// screen.
  static func positions(forCanvas graph: LoopGraph) -> [UUID: CGPoint] {
    var placed = LaneLayout(
      graph: graph, roles: CardEntryRole.roles(in: graph), rowHeight: rowHeight(for: graph)
    ).positions
    for node in graph.nodes {
      guard let subGraph = node.subGraph else { continue }
      placed.merge(positions(forCanvas: subGraph)) { current, _ in current }
    }
    return placed
  }

  /// The row pitch a canvas needs: the Graph view's own, unless a composite here is drawn
  /// open. A folder's canvas hangs a composite's insides below its card (`SubGraphLayout`),
  /// and those chips need more room under a card than the Graph view — which expands
  /// nothing — leaves between rows. Taller uniformly rather than only under the composites,
  /// because rows of two different heights is exactly the raggedness this layout is for.
  static func rowHeight(for graph: LoopGraph) -> CGFloat {
    let expandsSomething = graph.nodes.contains { $0.subGraph?.nodes.isEmpty == false }
    return expandsSomething ? max(Metrics.rowHeight, SubGraphLayout.rowPitch) : Metrics.rowHeight
  }

  /// How many hand-offs from a beginning each loop sits — its column.
  ///
  /// Capped by the walk itself rather than by a visited set: a cycle would otherwise raise
  /// its own depth forever, and the column is clamped to the lane's width anyway.
  private static func depths(in graph: LoopGraph, from starts: [UUID]) -> [UUID: Int] {
    var depths = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0) })
    var frontier = starts
    while let current = frontier.popLast() {
      let next = (depths[current] ?? 0) + 1
      guard next < Metrics.columns else { continue }
      for edge in graph.edges where edge.from == current {
        guard (depths[edge.to] ?? -1) < next else { continue }
        depths[edge.to] = next
        frontier.append(edge.to)
      }
    }
    return depths
  }
}
