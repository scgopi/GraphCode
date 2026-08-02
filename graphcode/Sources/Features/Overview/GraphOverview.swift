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
  /// One folder's lane header — the thing the start node actually tethers to. Clicking
  /// it selects that folder, so the overview is also how you get to a project's own
  /// canvas.
  ///
  /// Only real folders get one. The global graph is *this view* — a chip labelled
  /// "Graph" sitting inside the Graph, tethered to the Graph's own start node, says
  /// nothing you didn't already know from having clicked Graph to get here. Its own
  /// triggers still appear; they just hang straight off the start node, which is what
  /// they are: entry points that belong to no folder.
  struct Folder: Identifiable, Equatable {
    let path: String
    let name: String
    let loopCount: Int
    let position: CGPoint

    var id: String { path }
  }

  /// One loop card. Always a loop the folder's graph owns directly — every card here has
  /// a real session behind it, which is what makes every card clickable.
  struct Loop: Identifiable, Equatable {
    let node: LoopNode
    let projectPath: String
    let position: CGPoint

    var id: UUID { node.id }
  }

  /// Every line on the canvas, already resolved to two points — the shared `CanvasLink`,
  /// so the overview and a project's canvas can't drift on how a tether is drawn.
  typealias Link = CanvasLink

  var start: CGPoint = .zero
  var folders: [Folder] = []
  var loops: [Loop] = []
  var links: [Link] = []
  /// The canvas's extent, so the view can centre the whole picture instead of guessing.
  var size: CGSize = .zero

  var isEmpty: Bool { folders.isEmpty && loops.isEmpty }

  /// Loops drawn — the same number the sidebar lists, since both count a composite once.
  var loopCount: Int { loops.count }

  // MARK: - Layout

  private enum Metrics {
    static let startX: CGFloat = 90
    static let folderX: CGFloat = 300
    static let firstLoopX: CGFloat = 580
    static let columnWidth: CGFloat = 280
    static let rowHeight: CGFloat = 118
    static let laneGap: CGFloat = 56
    static let laneTop: CGFloat = 110
    static let columns = 4
  }

  init() {}

  init(graphs: [LoopGraph]) {
    // The global graph's lane goes first — it's the one that dispatches into the others,
    // so reading top-to-bottom follows the direction work actually travels. Stable
    // partition rather than a sort, so the remaining folders keep sidebar order. A global
    // graph with no triggers of its own is dropped outright: an empty lane with no chip
    // would be a band of blank canvas above everything with nothing to explain it.
    let lanes =
      graphs.filter { $0.isGlobal && !$0.nodes.isEmpty } + graphs.filter { !$0.isGlobal }
    // Even with nothing open the marker has to sit somewhere sensible: `.zero` would
    // park it in the window's top-left corner, reading as a stray dot rather than as
    // the origin of a graph that happens to be empty.
    start = CGPoint(x: Metrics.startX, y: Metrics.laneTop)
    guard !lanes.isEmpty else { return }

    // Filled in once every lane is placed, since the start node's own position depends on
    // where they all landed.
    var pendingTethers: [(id: String, to: CGPoint)] = []
    var laneCentres: [CGFloat] = []
    var laneTop = Metrics.laneTop

    for graph in lanes {
      let lane = Self.layOutLane(graph, top: laneTop)
      loops.append(contentsOf: lane.loops)
      links.append(contentsOf: lane.links)
      laneCentres.append(lane.folder.position.y)

      // A folder's entry points hang off its chip; the global graph has no chip, so its
      // triggers hang off the start node directly.
      if graph.isGlobal {
        pendingTethers += lane.anchorIDs.compactMap { anchorID in
          guard let target = lane.positions[anchorID] else { return nil }
          return (id: "start-trigger-\(anchorID)", to: target)
        }
      } else {
        folders.append(lane.folder)
        pendingTethers.append((id: "start-\(graph.project.path)", to: lane.folder.position))
        links.append(
          contentsOf: lane.anchorIDs.compactMap { anchorID in
            guard let target = lane.positions[anchorID] else { return nil }
            return Link(
              id: "anchor-\(graph.project.path)-\(anchorID)",
              from: lane.folder.position, to: target, kind: .tether)
          })
      }
      laneTop += lane.height + Metrics.laneGap
    }

    // Centred on the lanes rather than on the canvas, so the tethers fan out from the
    // middle of what they connect to however many folders are open.
    start = CGPoint(
      x: Metrics.startX, y: ((laneCentres.min() ?? 0) + (laneCentres.max() ?? 0)) / 2)
    links.append(
      contentsOf: pendingTethers.map {
        Link(id: $0.id, from: start, to: $0.to, kind: .tether)
      })

    size = CGSize(
      width: Metrics.firstLoopX + CGFloat(Metrics.columns) * Metrics.columnWidth,
      height: laneTop - Metrics.laneGap + Metrics.laneTop)
  }

  /// What one folder's lane came out as. `positions` is kept so the caller can draw the
  /// chip's tethers without re-deriving where anything landed.
  private struct Lane {
    let folder: Folder
    let loops: [Loop]
    let links: [Link]
    let positions: [UUID: CGPoint]
    let anchorIDs: [UUID]
    let height: CGFloat
  }

  private static func layOutLane(_ graph: LoopGraph, top: CGFloat) -> Lane {
    let path = graph.project.path
    var loops: [Loop] = []
    var links: [Link] = []
    var positions: [UUID: CGPoint] = [:]
    var rowTop = top

    for row in Array(graph.nodes).chunked(into: Metrics.columns) {
      for (column, node) in row.enumerated() {
        let position = CGPoint(
          x: Metrics.firstLoopX + CGFloat(column) * Metrics.columnWidth, y: rowTop)
        positions[node.id] = position
        loops.append(Loop(node: node, projectPath: path, position: position))
      }
      rowTop += Metrics.rowHeight
    }

    for edge in graph.edges {
      guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
      links.append(
        Link(
          id: "edge-\(edge.id)", from: from, to: to,
          kind: .edge(edge.kind, fired: edge.fired)))
    }

    // An empty folder still gets a lane a row tall — a chip tethered to nothing is how
    // the overview says "this folder has no loops yet", and collapsing it to zero height
    // would jam it against its neighbours instead.
    let height = max(rowTop - top, Metrics.rowHeight)
    let folder = Folder(
      path: path,
      name: graph.project.name,
      loopCount: graph.nodes.count,
      position: CGPoint(x: Metrics.folderX, y: top + height / 2 - Metrics.rowHeight / 2))

    return Lane(
      folder: folder, loops: loops, links: links, positions: positions,
      anchorIDs: graph.startAnchors, height: height)
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
