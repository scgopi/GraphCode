import Foundation
import GraphcodeKit

/// What ⌘K searches and how it ranks what it finds.
///
/// A workspace of four folders is thirty loops, and the two ways to reach one were a
/// sidebar you scroll and a canvas you pan. Neither is a way to reach a loop *whose name
/// you know*. This is that — and because it is, ranking is the whole feature: a palette
/// that puts a substring match above the loop you typed the first three letters of is a
/// palette you stop trusting after the second wrong Return.
///
/// Pure functions over the graphs, so the ranking is checkable without a keystroke.
enum JumpPalette {
  struct Result: Identifiable, Equatable {
    let nodeID: UUID
    let projectPath: String
    let title: String
    let projectName: String
    let loopType: LoopType
    let state: LoopState
    /// Whether the rollup says this one wants a human. Sorts first on an empty query and
    /// breaks ties everywhere else — the palette opens on what you most likely came for.
    let needsHuman: Bool

    var id: UUID { nodeID }

    /// `"Goal · RUNNING · graphcode"`.
    var subtitle: String {
      "\(loopType.displayName) · \(state.displayWord(for: loopType)) · \(projectName)"
    }
  }

  /// How well a loop answers what was typed. Lower is better; the order of the cases is
  /// the ranking, so reading it top to bottom is reading the rule.
  private enum Rank: Int, Comparable {
    /// You typed the start of its name. Nothing outranks this.
    case titlePrefix
    /// The words are in the name somewhere.
    case titleSubstring
    /// The kind or the state — `"running"`, `"timed"` — which is a way of asking for a
    /// *set* of loops rather than one.
    case attribute
    /// Only the folder matched, so this is every loop in it.
    case projectName

    static func < (lhs: Rank, rhs: Rank) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  static func results(
    query: String, graphs: [(graph: LoopGraph, path: String)], attention: Set<UUID>
  ) -> [Result] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    let all = graphs.flatMap { entry in
      entry.graph.nodes.map { node in
        Result(
          nodeID: node.id,
          projectPath: entry.path,
          title: node.title,
          projectName: entry.graph.project.name,
          loopType: node.loopType,
          state: node.state,
          needsHuman: attention.contains(node.id))
      }
    }

    guard !needle.isEmpty else {
      // Nothing typed yet: the loops waiting on a human, then everything else in the
      // order the sidebar draws it. Opening on an arbitrary loop would make the first
      // keystroke mandatory. A partition rather than a sort — `sorted` is not stable, so
      // sorting on one boolean would shuffle the rest into no order at all.
      return all.filter(\.needsHuman) + all.filter { !$0.needsHuman }
    }

    return
      all
      .compactMap { result in rank(result, matching: needle).map { (result, $0) } }
      .sorted { lhs, rhs in
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        if lhs.0.needsHuman != rhs.0.needsHuman { return lhs.0.needsHuman }
        return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
      }
      .map(\.0)
  }

  private static func rank(_ result: Result, matching needle: String) -> Rank? {
    let title = result.title.lowercased()
    if title.hasPrefix(needle) { return .titlePrefix }
    if title.contains(needle) { return .titleSubstring }
    let kind = result.loopType.displayName.lowercased()
    let word = result.state.displayWord(for: result.loopType).lowercased()
    if kind.contains(needle) || word.contains(needle) { return .attribute }
    if result.projectName.lowercased().contains(needle) { return .projectName }
    return nil
  }
}
