import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The activity strip's slice of the root feature: the observed half of the feed.
///
/// A node says what state it is in, never when it got there, so the only way to know a
/// loop started running at 14:02 is to have been watching at 14:02. This does that
/// watching — one comparison per broadcast, against the graph already in state — which
/// is the whole reason the strip needs no event log, no schema and no file.
///
/// Split out of `AppFeature` for the reason the ⌘K and Quick Chats slices are: it is a
/// separate subject over the same state.
extension AppFeature {
  /// How many observed events are kept. Half an hour of a busy workspace, and a hard
  /// bound on state that lives for as long as the app does.
  static let activityLogLimit = 200

  /// Records what changed between the graph we had and the one that just arrived.
  ///
  /// Only transitions, and only for loops that were already there: a broadcast carrying
  /// a project's whole graph for the first time would otherwise land as one event per
  /// node, all stamped now, describing nothing that happened while anyone was looking.
  static func recordActivity(
    previous: LoopGraph?, next: LoopGraph, path: String, at now: Date,
    into log: inout [ActivityEvent]
  ) {
    guard let previous else { return }
    for node in next.nodes {
      guard let before = previous.nodes[id: node.id], before.state != node.state else {
        continue
      }
      log.append(
        ActivityEvent(
          id: "state-\(node.id)-\(node.state)-\(now.timeIntervalSince1970)",
          at: now,
          nodeID: node.id,
          projectPath: path,
          nodeTitle: node.title,
          kind: .state(node.state)))
    }
    if log.count > activityLogLimit { log.removeFirst(log.count - activityLogLimit) }
  }
}

extension AppFeature.State {
  /// What the strip draws — the observed log merged with what the graphs themselves
  /// remember. Derived per body pass like every other list here, and cheap: the log is
  /// bounded and the derivation is two passes over nodes and edges.
  func activityEvents(now: Date) -> [ActivityEvent] {
    ActivityFeed.events(
      derivedFrom: projects.map { (graph: $0.graph, path: $0.id) },
      observed: activityLog,
      now: now,
      attentionOnly: activityFilterIsAttention)
  }
}
