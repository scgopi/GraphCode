import CoreGraphics
import Foundation
import GraphcodeKit

/// Every open folder's loops laid out as one graph, hanging off a single start node —
/// what the sidebar's pinned **Graph** row shows (docs/06-ux-terminals.md#the-graph-view).
///
/// The sidebar already lists every loop across every folder, but as a flat list it says
/// nothing about how they relate: which loop starts a chain, which hands off to which.
/// This is that same set of sessions drawn as the structure it already is — one origin, a
/// lane per folder, and that folder's loops in it.
///
/// **One card per loop, and nothing below that.** A composite's `subGraph` is not
/// expanded here: this view's job is to show every loop in the workspace, and a composite
/// that fans out to a dozen templates would drown the folder it sits in under a dozen
/// things that aren't running. The card's live line says how big the composite is and
/// whether it is armed, and the composite's own canvas is where its insides are for.
///
/// A pure value computed from the graphs `graphcoded` broadcasts, so there is nothing to
/// keep in sync and nothing to persist: recomputing it is cheaper than reconciling a
/// cached copy against the next `.graphChanged`. Positions are deliberately *derived*
/// rather than stored — this is a viewer, not a second canvas you arrange by hand.
struct GraphOverview: Equatable {
  /// One folder's lane: the band its loops sit in, and the caption on it.
  ///
  /// This replaced a chip tethered to a start marker. The chip said a name and a count
  /// and needed a line drawn to it to explain what it belonged to; the band *contains*
  /// what it belongs to, which is the same statement made by position instead of by ink,
  /// and it leaves the caption free to say how the folder is doing rather than only how
  /// big it is.
  ///
  /// The global graph gets a lane too, captioned for what it is — loops that belong to
  /// no folder. It is not named "Graph": a band labelled Graph inside the Graph says
  /// nothing you didn't know from having clicked Graph to get here.
  struct Folder: Identifiable, Equatable {
    let path: String
    let name: String
    let loopCount: Int
    /// `"5 loops · 3 running"`, or `nil` for a folder with nothing in it yet — see
    /// `Self.caption`.
    let caption: String?
    /// Every root's port in this lane, for the band's entry rail.
    let entryPorts: [CGPoint]
    let isGlobal: Bool
    /// The band, in canvas coordinates. Its top-left corner is where the caption goes.
    let band: CGRect

    var id: String { path }
  }

  /// One loop card. Always a loop the folder's graph owns directly — every card here has
  /// a real session behind it, which is what makes every card clickable.
  struct Loop: Identifiable, Equatable {
    let node: LoopNode
    let projectPath: String
    let position: CGPoint
    /// Where this loop sits in "where does the graph begin" — resolved once here, off
    /// the graph, rather than per card on the gesture path.
    let entryRole: CardEntryRole

    var id: UUID { node.id }

    /// The centre of the entry port on this card's leading edge, when it has one —
    /// every loop nothing hands off to, whether it hands off to something (a root) or to
    /// nothing (an accident). Both hang off the lane's origin; only the second is drawn
    /// as a mistake.
    var entryPort: CGPoint? {
      guard entryRole == .entry || entryRole == .unwired else { return nil }
      return CGPoint(x: position.x - Metrics.card.width / 2, y: position.y)
    }
  }

  /// Every line on the canvas, already resolved to two points — the shared `CanvasLink`,
  /// so the overview and a project's canvas can't drift on how a tether is drawn.
  typealias Link = CanvasLink

  var folders: [Folder] = []
  var loops: [Loop] = []
  var links: [Link] = []
  /// The canvas's extent, so the view can centre the whole picture instead of guessing.
  var size: CGSize = .zero

  var isEmpty: Bool { folders.isEmpty && loops.isEmpty }

  /// Loops drawn — the same number the sidebar lists, since both count a composite once.
  var loopCount: Int { loops.count }

  // MARK: - Layout

  enum Metrics {
    static let card = LoopCardView.Metrics.size
    /// Every band starts at the same x and is the same width, however few loops are in
    /// it. Ragged lanes read as a collage; aligned ones read as a table of projects.
    static let bandX: CGFloat = 20
    /// Clear of the attention rail, which floats over the canvas's top-left corner.
    static let laneTop: CGFloat = 62
    static let laneGap: CGFloat = 24
    static let columnGap: CGFloat = 40
    static let rowGap: CGFloat = 24
    static let columns = 4

    static let columnWidth = card.width + columnGap
    static let rowHeight = card.height + rowGap
    static let bandWidth =
      CanvasBand.padding * 2 + CanvasBand.originLane + CGFloat(columns) * card.width
      + CGFloat(columns - 1) * columnGap
    /// The first card's centre, inside the band and below the caption.
    static let firstLoopX =
      bandX + CanvasBand.padding + CanvasBand.originLane + card.width / 2
    static let firstRowInset = CanvasBand.captionHeight + CanvasBand.padding + card.height / 2
  }

  init() {}

  init(graphs: [LoopGraph]) {
    // The global graph's lane goes first — it's the one that dispatches into the others,
    // so reading top-to-bottom follows the direction work actually travels. Stable
    // partition rather than a sort, so the remaining folders keep sidebar order. A global
    // graph with no triggers of its own is dropped outright: an empty lane would be a
    // band of blank canvas above everything with nothing to explain it.
    let lanes =
      graphs.filter { $0.isGlobal && !$0.nodes.isEmpty } + graphs.filter { !$0.isGlobal }
    guard !lanes.isEmpty else { return }

    var laneTop = Metrics.laneTop
    for graph in lanes {
      let lane = Self.layOutLane(graph, top: laneTop)
      folders.append(lane.folder)
      loops.append(contentsOf: lane.loops)
      links.append(contentsOf: lane.links)
      laneTop = lane.folder.band.maxY + Metrics.laneGap
    }

    size = CGSize(
      width: Metrics.bandX * 2 + Metrics.bandWidth,
      height: laneTop - Metrics.laneGap + Metrics.laneTop)
  }

  /// What one folder's lane came out as.
  private struct Lane {
    let folder: Folder
    let loops: [Loop]
    let links: [Link]
  }

  /// How many hand-offs from a beginning each loop sits — its column.
  ///
  /// Capped by the walk itself rather than by a visited set: a cycle would otherwise
  /// raise its own depth forever, and the column is clamped to the lane's width anyway.
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

  private static func layOutLane(_ graph: LoopGraph, top: CGFloat) -> Lane {
    let path = graph.project.path
    let roles = CardEntryRole.roles(in: graph)
    var loops: [Loop] = []
    var links: [Link] = []
    var positions: [UUID: CGPoint] = [:]

    // Entry points first, then everything else, each group keeping its own order.
    //
    // Position is what makes the rail mean anything: a rail down the lane's leading edge
    // with a 12pt stub to each port only reaches cards in the first column, and an entry
    // sitting three columns right would need a connector long enough to read as an edge —
    // which is exactly what a rail must not imply. Laying the roots out first also makes
    // the lane read left-to-right in the direction work actually travels.
    // Laid out by *depth from a beginning* rather than in graph order: everything
    // nothing hands off to goes in column 0, one per row, and each chain flows right
    // along its own row.
    //
    // Filling rows left-to-right put all four rootless cards of a real graph side by
    // side, which hid the origin's fan behind them — cards draw over the lines, so the
    // connectors showed only in the gaps and read as one card chained to the next. A
    // column of beginnings is also how the graph reads: down the left is where work
    // starts, across is where it goes.
    let hangsOffOrigin: (LoopNode) -> Bool = {
      roles[$0.id] == .entry || roles[$0.id] == .unwired
    }
    let starts = Array(graph.nodes).filter(hangsOffOrigin)
    let depths = Self.depths(in: graph, from: starts.map(\.id))

    var slots: [UUID: (column: Int, row: Int)] = [:]
    var takenRows: Set<Int> = []
    var occupied: Set<String> = []

    func place(_ node: LoopNode, preferring row: Int) {
      guard slots[node.id] == nil else { return }
      let column = min(depths[node.id] ?? 0, Metrics.columns - 1)
      var candidate = row
      while occupied.contains("\(column)-\(candidate)") { candidate += 1 }
      slots[node.id] = (column, candidate)
      occupied.insert("\(column)-\(candidate)")
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
    for node in graph.nodes where slots[node.id] == nil {
      while takenRows.contains(nextRow) { nextRow += 1 }
      place(node, preferring: nextRow)
    }

    for node in graph.nodes {
      guard let slot = slots[node.id] else { continue }
      let position = CGPoint(
        x: Metrics.firstLoopX + CGFloat(slot.column) * Metrics.columnWidth,
        y: top + Metrics.firstRowInset + CGFloat(slot.row) * Metrics.rowHeight)
      positions[node.id] = position
      loops.append(
        Loop(
          node: node, projectPath: path, position: position,
          entryRole: roles[node.id] ?? .interior))
    }
    let rowCount = max((slots.values.map(\.row).max() ?? 0) + 1, 1)

    for edge in graph.edges {
      guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
      links.append(
        Link(
          id: "edge-\(edge.id)", from: from, to: to,
          kind: .edge(edge.kind, fired: edge.fired), label: edge.cycleLabel))
    }

    // An empty folder still gets a band one row tall — that is how the overview says
    // "this folder has no loops yet", and collapsing it to its caption would leave a
    // sliver jammed against the lane below.
    let rows = graph.nodes.isEmpty ? 1 : rowCount
    let height =
      CanvasBand.captionHeight + CanvasBand.padding * 2 + CGFloat(rows) * Metrics.card.height
      + CGFloat(rows - 1) * Metrics.rowGap
    let folder = Folder(
      path: path,
      name: graph.isGlobal ? "No folder" : graph.project.name,
      loopCount: graph.nodes.count,
      caption: caption(for: graph),
      entryPorts: loops.compactMap(\.entryPort),
      isGlobal: graph.isGlobal,
      band: CGRect(x: Metrics.bandX, y: top, width: Metrics.bandWidth, height: height))

    return Lane(folder: folder, loops: loops, links: links)
  }

  /// `"5 loops · 3 running"`.
  ///
  /// The second half counts the nodes in the graph's own `aggregateState` rather than
  /// counting states itself — one rollup, read twice, so a lane can never claim a folder
  /// is fine while the sidebar's monitor says it isn't. `aggregateState` already ranks
  /// worst-first, which is what makes the count worth reading: it is a count of the thing
  /// most worth knowing about this folder.
  static func caption(for graph: LoopGraph) -> String? {
    guard !graph.nodes.isEmpty else { return nil }
    let loops = graph.nodes.count == 1 ? "1 loop" : "\(graph.nodes.count) loops"
    let state = graph.aggregateState
    // Nothing is happening, so say something that is: how many places this lane starts.
    // "10 loops · 10 idle" is a count of the absence of news.
    guard state != .idle else {
      let entries = graph.entryPoints.count
      guard entries > 0 else { return loops }
      return "\(loops) · \(entries) entry point\(entries == 1 ? "" : "s")"
    }
    let matching = graph.nodes.count { $0.displayState == state }
    // The kind-independent reading of the word: a lane is speaking about a folder, and a
    // folder has no loop type for `idle` to mean "scheduled" against.
    return "\(loops) · \(matching) \(state.displayWord(for: .goalBased).lowercased())"
  }
}

extension Array {
  /// Fixed-width rows for the lane layout. `chunked(into:)` isn't in the standard
  /// library and the alternative — index arithmetic inline in the layout — is where
  /// off-by-one row bugs live.
  fileprivate func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return isEmpty ? [] : [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
