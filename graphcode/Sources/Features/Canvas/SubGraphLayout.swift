import CoreGraphics
import Foundation
import GraphcodeKit
import IdentifiedCollections

/// A folder canvas's composites, opened up: every loop inside a `.proactive` node's
/// `subGraph`, placed under the card that owns it, with the lines that say what contains
/// what and how the insides are wired.
///
/// **This is where sub-graphs belong.** The Graph view deliberately shows one card per
/// loop and expands nothing (see `GraphOverview`) — it exists to show the whole workspace
/// at once, and a composite that fans out to a dozen templates would bury the folder it
/// sits in. A folder's own canvas is the opposite: it's already scoped to one repo, so it
/// has the room, and "what is actually inside this composite" is the question you came to
/// that canvas to answer.
///
/// A pure value, like `GraphOverview` and for the same reasons: derived from the graph the
/// daemon broadcast plus the card positions the canvas already has, so there is nothing to
/// keep in sync.
struct SubGraphLayout: Equatable {
  /// One loop inside a composite. `depth` is 1 for a direct child, 2+ for a composite
  /// nested inside a composite.
  struct Placement: Identifiable, Equatable {
    let node: LoopNode
    let depth: Int
    let position: CGPoint

    var id: UUID { node.id }
  }

  /// "+3 more", when a composite holds more loops than fit in the space under its card.
  ///
  /// The alternative was drawing them all and letting them collide with the row below —
  /// the canvas lays cards out on a fixed grid, so the room under a card is finite. A
  /// count that admits what it's hiding beats a pile of overlapping chips, and beats
  /// silently dropping them.
  struct Overflow: Identifiable, Equatable {
    let parent: UUID
    let hidden: Int
    let position: CGPoint

    var id: UUID { parent }
  }

  var placements: [Placement] = []
  var links: [CanvasLink] = []
  var overflows: [Overflow] = []

  var isEmpty: Bool { placements.isEmpty }

  private enum Metrics {
    /// Clear of the parent card's bottom edge (cards are ~90pt tall, centred).
    static let firstOffset: CGFloat = 56
    static let step: CGFloat = 28
    /// Each level of nesting steps right, so depth reads off the left edge.
    static let indent: CGFloat = 14
    /// The grid's row pitch is 200pt and a card reaches ~45pt below its centre, so this
    /// many chips is what fits before the next row's card. Past it, `Overflow`.
    static let maxVisible = 4
  }

  init() {}

  init(nodes: IdentifiedArrayOf<LoopNode>, positions: [UUID: CGPoint]) {
    for node in nodes {
      guard node.subGraph != nil, let anchor = positions[node.id] else { continue }
      let contents = Self.contents(of: node, depth: 1)
      guard !contents.entries.isEmpty else { continue }

      // Keep a slot for the "+N more" chip rather than letting it push a real one out.
      let overflowing = contents.entries.count > Metrics.maxVisible
      let visible =
        overflowing
        ? Array(contents.entries.prefix(Metrics.maxVisible - 1)) : contents.entries

      var placed: [UUID: CGPoint] = [node.id: anchor]
      for (slot, entry) in visible.enumerated() {
        let position = CGPoint(
          x: anchor.x + CGFloat(entry.depth) * Metrics.indent,
          y: anchor.y + Metrics.firstOffset + CGFloat(slot) * Metrics.step)
        placed[entry.node.id] = position
        placements.append(
          Placement(node: entry.node, depth: entry.depth, position: position))
        // Pre-order, so a nested composite is always placed before its own children —
        // which is what lets a depth-2 chip point at the depth-1 chip that holds it
        // rather than at the top-level card.
        if let parent = placed[entry.parent] {
          links.append(
            CanvasLink(
              id: "contains-\(entry.parent)-\(entry.node.id)",
              from: parent, to: position, kind: .containment))
        }
      }

      if overflowing {
        overflows.append(
          Overflow(
            parent: node.id,
            hidden: contents.entries.count - visible.count,
            position: CGPoint(
              x: anchor.x + Metrics.indent,
              y: anchor.y + Metrics.firstOffset + CGFloat(visible.count) * Metrics.step)))
      }

      // The sub-graph's own wiring, drawn exactly as a top-level edge is. Only where both
      // ends are on screen — an edge into a hidden chip would be a line to nowhere.
      for edge in contents.edges {
        guard let from = placed[edge.from], let to = placed[edge.to] else { continue }
        links.append(
          CanvasLink(
            id: "sub-edge-\(edge.id)", from: from, to: to,
            kind: .edge(edge.kind, fired: edge.fired)))
      }
    }
  }

  /// Everything inside a composite, depth-first and depth-tagged, plus every sub-graph's
  /// own edges. Recursive because a composite can contain a composite, which
  /// `LoopGraph.reIdentified` already treats as ordinary.
  private static func contents(of node: LoopNode, depth: Int) -> Contents {
    guard let subGraph = node.subGraph else { return Contents() }
    var found = Contents(entries: [], edges: Array(subGraph.edges))
    for child in subGraph.nodes {
      found.entries.append(Entry(node: child, parent: node.id, depth: depth))
      let nested = contents(of: child, depth: depth + 1)
      found.entries.append(contentsOf: nested.entries)
      found.edges.append(contentsOf: nested.edges)
    }
    return found
  }
}

/// One loop found inside a composite, and the node it was found in. Carrying the parent
/// is what lets a containment line point at the right chip once nesting goes more than
/// one level deep.
private struct Entry {
  let node: LoopNode
  let parent: UUID
  let depth: Int
}

/// A composite's insides: what it holds, and how those are wired to each other.
private struct Contents {
  var entries: [Entry] = []
  var edges: [LoopEdge] = []
}
