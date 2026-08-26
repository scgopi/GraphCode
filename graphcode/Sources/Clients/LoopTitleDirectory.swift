import Dependencies
import Foundation
import GraphcodeKit

/// Every node title the app currently knows, across every open project — local
/// folders, remote repositories, and the Graph — for the one consumer that needs the
/// cross-project view: `TitleSuggestionClient`, whose generated names must not collide
/// with anything already on any canvas.
///
/// Each project's reducer registers its graph on every `.graphChanged` broadcast, so
/// the directory is only ever as current as the last broadcast — enough for naming,
/// where a stale entry merely keeps a just-deleted name retired one beat longer.
struct LoopTitleDirectory: Sendable {
  var register: @Sendable (_ projectPath: String, _ graph: LoopGraph) -> Void
  var allTitles: @Sendable () -> Set<String>
}

extension LoopTitleDirectory: DependencyKey {
  static let liveValue: LoopTitleDirectory = {
    let titles = LockIsolated<[String: Set<String>]>([:])
    return LoopTitleDirectory(
      register: { path, graph in
        titles.withValue { $0[path] = collectTitles(in: graph) }
      },
      allTitles: {
        titles.withValue { stored in stored.values.reduce(into: Set()) { $0.formUnion($1) } }
      })
  }()

  /// Reducer tests exercise node creation without caring about names elsewhere.
  static let testValue = LoopTitleDirectory(register: { _, _ in }, allTitles: { [] })

  /// A composite's children live in its `subGraph`, and their names are just as taken.
  static func collectTitles(in graph: LoopGraph) -> Set<String> {
    graph.nodes.reduce(into: Set()) { titles, node in
      titles.insert(node.title)
      if let subGraph = node.subGraph { titles.formUnion(collectTitles(in: subGraph)) }
    }
  }
}

extension DependencyValues {
  var loopTitleDirectory: LoopTitleDirectory {
    get { self[LoopTitleDirectory.self] }
    set { self[LoopTitleDirectory.self] = newValue }
  }
}
