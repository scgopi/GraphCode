import Foundation
import GraphcodeKit

/// What happened recently, across every open folder.
///
/// **Derived, not logged.** Nothing persists an event stream, and this deliberately does
/// not add one: two of the three kinds of event are already recoverable from the graphs
/// the daemon broadcasts — a metric sample carries the time it was taken, and a fired
/// edge carries the fact that it fired. Only state changes need watching, because a node
/// records what it *is* and not when it became that, and those are observed as broadcasts
/// arrive (`AppFeature.recordActivity`).
///
/// The cost of that choice is honest and worth stating: the feed starts empty at launch
/// and only knows about state changes seen since. A persisted log in `GraphStore` is the
/// answer if this proves too thin — but it is a schema, a migration and a file to keep
/// bounded, and the derived version is free.
struct ActivityEvent: Identifiable, Equatable {
  enum Kind: Equatable {
    /// A goal loop's metric was sampled — one pass finished.
    case pass(value: Double)
    /// An edge fired: work moved from one loop to another.
    case handoff(target: String)
    /// A loop changed state, as seen between two broadcasts.
    case state(LoopState)
  }

  let id: String
  let at: Date
  let nodeID: UUID
  let projectPath: String
  let nodeTitle: String
  let kind: Kind

  /// Whether this is one of the events the strip's filter keeps. A state change into
  /// something that wants a human, or into failure — the things you would want to have
  /// noticed while you were reading something else.
  var isAttention: Bool {
    guard case .state(let state) = kind else { return false }
    return state.wantsHuman || state == .failed || state == .stalled
  }

  var text: String {
    switch kind {
    case .pass(let value):
      return "\(nodeTitle) · pass \(LoopCardPresentation.number(value))"
    case .handoff(let target):
      return "\(nodeTitle) → \(target)"
    case .state(let state):
      return "\(nodeTitle) · \(state.displayWord(for: .goalBased).lowercased())"
    }
  }

  var timestamp: String { at.formatted(date: .omitted, time: .shortened) }
}

enum ActivityFeed {
  /// How far back the strip looks. Longer than a coffee break, shorter than a working
  /// day: a strip claiming "last 30 min" and showing something from this morning is a
  /// strip nobody can date at a glance.
  static let window: TimeInterval = 30 * 60

  /// Everything the graphs themselves remember: metric samples and fired edges. State
  /// changes come from the observed log and are merged in by the caller.
  static func derived(from graphs: [(graph: LoopGraph, path: String)]) -> [ActivityEvent] {
    graphs.flatMap { entry -> [ActivityEvent] in
      let passes = entry.graph.nodes.flatMap { node in
        node.metricHistory.enumerated().map { index, sample in
          ActivityEvent(
            id: "pass-\(node.id)-\(index)",
            at: sample.recordedAt,
            nodeID: node.id,
            projectPath: entry.path,
            nodeTitle: node.title,
            kind: .pass(value: sample.value))
        }
      }
      // A fired edge has no timestamp of its own, so it is dated by the target it
      // unblocked — which is when the handoff actually mattered to anyone. Only edges
      // whose target has moved since being created are dated at all; the rest would all
      // claim the same instant and pile up at one end of the strip.
      let handoffs = entry.graph.edges.compactMap { edge -> ActivityEvent? in
        guard edge.fired, edge.fireCount > 0,
          let source = entry.graph.nodes[id: edge.from],
          let target = entry.graph.nodes[id: edge.to]
        else { return nil }
        return ActivityEvent(
          id: "edge-\(edge.id)-\(edge.fireCount)",
          at: target.createdAt,
          nodeID: source.id,
          projectPath: entry.path,
          nodeTitle: source.title,
          kind: .handoff(target: target.title))
      }
      return passes + handoffs
    }
  }

  /// The strip's contents: derived events and observed state changes, newest first,
  /// inside the window.
  static func events(
    derivedFrom graphs: [(graph: LoopGraph, path: String)],
    observed: [ActivityEvent],
    now: Date,
    attentionOnly: Bool = false
  ) -> [ActivityEvent] {
    let cutoff = now.addingTimeInterval(-window)
    var seen: Set<String> = []
    return (observed + derived(from: graphs))
      .filter { $0.at >= cutoff && $0.at <= now }
      .filter { !attentionOnly || $0.isAttention }
      .filter { seen.insert($0.id).inserted }
      .sorted { $0.at > $1.at }
  }

  /// `"last 30 min · 11 events"`.
  static func summary(_ events: [ActivityEvent]) -> String {
    let count = events.count == 1 ? "1 event" : "\(events.count) events"
    return "last \(Int(window / 60)) min · \(count)"
  }
}
