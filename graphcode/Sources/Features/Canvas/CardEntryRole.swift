import GraphcodeKit
import SwiftUI

/// Where a loop sits in the question the start node used to answer badly: where does
/// this graph begin?
///
/// The marker solved a real problem — roots have no inbound edge to be found by, and a
/// closed cycle has no root at all — with furniture that lied (nothing travels a tether)
/// and that failed at scale: every unconnected loop is a root by that rule, so ten loose
/// loops fanned ten lines out of one dot. Each case here gets an answer that belongs to
/// the *card*, which is why N of them cost nothing.
enum CardEntryRole: Equatable {
  /// Something upstream hands off to it. The common case, and it draws nothing.
  case interior
  /// Nothing hands off to it, and it hands off to something: a real beginning.
  case entry
  /// In a component where every node has an inbound edge. `LoopGraph.startAnchors` has
  /// to pick one of these arbitrarily so the graph has somewhere to be read from; the
  /// card says the truth instead, which is that this cycle has no beginning.
  case cycleOnly
  /// No edge in either direction — usually an accident rather than a root.
  case unwired

  /// Built once for a whole graph. The individual `LoopGraph` properties each walk the
  /// edge list, so asking per card would be quadratic on the canvas's gesture path —
  /// the same trap `ProjectCanvasView.Derived` documents for the attention rollup.
  ///
  /// `declaredEntries` are loops a human answered "Mark as entry" for. Deliberately not
  /// persisted graph state: the graph's own answer to "is this a beginning" is its
  /// edges, and a stored flag would be a second answer able to disagree with them. This
  /// is one session's acknowledgement that a loose loop is on purpose — and if the loop
  /// is still loose next launch, the question is worth asking again.
  static func roles(
    in graph: LoopGraph, declaredEntries: Set<UUID> = []
  ) -> [UUID: CardEntryRole] {
    let unwired = graph.unwiredNodeIDs
    let cycleOnly = graph.cycleOnlyNodeIDs
    let entries = Set(graph.entryPoints)
    return Dictionary(
      uniqueKeysWithValues: graph.nodes.map { node in
        if declaredEntries.contains(node.id) { return (node.id, .entry) }
        if unwired.contains(node.id) { return (node.id, .unwired) }
        if cycleOnly.contains(node.id) { return (node.id, .cycleOnly) }
        if entries.contains(node.id) { return (node.id, .entry) }
        return (node.id, .interior)
      })
  }
}

/// The `entry` word in a card's meta row.
///
/// The port alone would be enough on a canvas at 100%. It isn't enough anywhere else:
/// greyscale, 40% zoom, or a sidebar row have no port, and "this is where it starts" is
/// exactly the kind of fact that has to survive all three.
struct EntryChip: View {
  var body: some View {
    Text("entry")
      .font(.system(size: 10.5, weight: .bold))
      .foregroundStyle(Self.ink)
      .padding(.vertical, 1)
      .padding(.horizontal, 6)
      .background(Self.fill, in: RoundedRectangle(cornerRadius: 4))
  }

  private static let fill = Color(red: 0.098, green: 0.620, blue: 0.439).opacity(0.18)
  private static let ink = Color(red: 0.435, green: 0.827, blue: 0.671)  // #6fd3ab
}

/// What a closed cycle gets instead of a port.
struct CycleChip: View {
  var body: some View {
    Text("cycle · no entry point")
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(Self.ink)
      .padding(.vertical, 1)
      .padding(.horizontal, 6)
      .background(Self.fill, in: RoundedRectangle(cornerRadius: 5))
      .overlay {
        RoundedRectangle(cornerRadius: 5).stroke(Self.border, lineWidth: 1)
      }
  }

  private static let ink = Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.9)
  private static let fill = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.12)
  private static let border = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.28)
}
