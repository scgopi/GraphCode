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
    var originPosition: CGPoint {
      CGPoint(x: band.minX + CanvasBand.originLane / 2, y: band.midY)
    }
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
  var startNode: CGPoint?
  /// The canvas's extent, so the view can centre the whole picture instead of guessing.
  var size: CGSize = .zero

  var isEmpty: Bool { folders.isEmpty && loops.isEmpty }

  /// The lanes the start node tethers to — only those with an entry port to land on.
  /// An empty folder draws no origin dot, so a connector to it points at nothing; the
  /// same goes for a cycle-only lane, whose deliberate mark is a chip, not a port.
  var tetheredFolders: [Folder] { folders.filter { !$0.entryPorts.isEmpty } }

  /// Loops drawn — the same number the sidebar lists, since both count a composite once.
  var loopCount: Int { loops.count }

  // MARK: - Layout

  /// The lane's own furniture. Everything about where a *card* goes lives in `LaneLayout`
  /// instead, which is what a folder's canvas lays itself out with too.
  enum Metrics {
    static let card = LaneLayout.Metrics.card
    static let startNodeLane: CGFloat = 60
    /// Every band starts at the same x and is the same width, however few loops are in
    /// it. Ragged lanes read as a collage; aligned ones read as a table of projects.
    static let bandX = LaneLayout.Metrics.bandX
    static let laneTop = LaneLayout.Metrics.laneTop
    static let laneGap: CGFloat = 24
    static let rowGap = LaneLayout.Metrics.rowGap
    static let bandWidth = LaneLayout.Metrics.bandWidth
    /// The first card's centre, inside the band and below the caption.
    static let firstLoopX = LaneLayout.Metrics.firstLoopX
    static let firstRowInset = LaneLayout.Metrics.firstRowInset
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

    if !folders.isEmpty {
      let minY = folders.map(\.band.minY).min()!
      let maxY = folders.map(\.band.maxY).max()!
      startNode = CGPoint(x: Metrics.startNodeLane / 2, y: (minY + maxY) / 2)
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

  private static func layOutLane(_ graph: LoopGraph, top: CGFloat) -> Lane {
    let path = graph.project.path
    let roles = CardEntryRole.roles(in: graph)
    var loops: [Loop] = []
    var links: [Link] = []

    // The shared layout, offset to this lane's own top — the same placement a folder's
    // own canvas gets, so the two views can't drift on what a graph looks like.
    let layout = LaneLayout(
      graph: graph, roles: roles,
      origin: CGPoint(x: Metrics.firstLoopX, y: top + Metrics.firstRowInset))
    let positions = layout.positions

    for node in graph.nodes {
      guard let position = positions[node.id] else { continue }
      loops.append(
        Loop(
          node: node, projectPath: path, position: position,
          entryRole: roles[node.id] ?? .interior))
    }

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
    let rows = graph.nodes.isEmpty ? 1 : layout.rowCount
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
