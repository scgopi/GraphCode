import Foundation

/// Why a loop is asking for a human, and how loudly — the ranking behind
/// docs/05-orchestrator.md#monitoring-surface's needs-attention rollup.
///
/// Ordered worst-first. `Comparable` is derived from that declaration order, so sorting
/// a mixed list of reasons puts the things that are actually broken above the things
/// that are merely waiting.
public enum AttentionReason: String, Codable, CaseIterable, Comparable, Sendable {
  /// The loop ran and did not succeed.
  case failed
  /// It blew its stall bound without ever resolving — arguably worse than failing,
  /// since nothing was learned, but it ranks second because a failure is a definite
  /// answer a human can act on immediately.
  case stalled
  /// The session is asking a question and nothing is moving until it's answered.
  case awaitingInput
  /// Waiting on an upstream that can no longer arrive. Not an error on its own, which
  /// is why it ranks last — but a graph full of these usually means one earlier problem.
  case blocked

  public var displayName: String {
    switch self {
    case .failed: return "Failed"
    case .stalled: return "Stalled"
    case .awaitingInput: return "Awaiting input"
    case .blocked: return "Blocked"
    }
  }

  public static func < (lhs: AttentionReason, rhs: AttentionReason) -> Bool {
    guard let l = allCases.firstIndex(of: lhs), let r = allCases.firstIndex(of: rhs) else {
      return false
    }
    return l < r
  }
}

/// One loop that wants a human, with enough context to act on without opening anything.
public struct AttentionItem: Identifiable, Equatable, Sendable {
  public let nodeID: UUID
  public let nodeTitle: String
  public let projectPath: String
  public let projectName: String
  public let reason: AttentionReason
  /// The node's own `createdAt`, carried so a surface can say *how long* this has been
  /// waiting without going back to the graph for it. The rollup already sorts on it; a
  /// queue that shows "oldest 12m" and a rail that reviews oldest-first would otherwise
  /// each have to re-derive an age the rollup had in hand and threw away.
  public let createdAt: Date

  public var id: UUID { nodeID }

  public init(
    nodeID: UUID, nodeTitle: String, projectPath: String, projectName: String,
    reason: AttentionReason, createdAt: Date
  ) {
    self.nodeID = nodeID
    self.nodeTitle = nodeTitle
    self.projectPath = projectPath
    self.projectName = projectName
    self.reason = reason
    self.createdAt = createdAt
  }
}

extension Array where Element == AttentionItem {
  /// The same queue, oldest first — what ⌘⇧R steps through and what the attention rail
  /// counts an age from.
  ///
  /// A second reading of one list, never a second rollup. Worst-first is right for a
  /// list you *read* (the broken thing belongs at the top); oldest-first is right for a
  /// queue you *work* (the thing ignored longest goes next, and repeat presses can't
  /// keep landing on the same loop).
  public var oldestFirst: [AttentionItem] {
    sorted { $0.createdAt == $1.createdAt ? $0.reason < $1.reason : $0.createdAt < $1.createdAt }
  }
}

/// The rollup itself: "surface the one thing that needs me, don't make me hunt for it
/// across N panes", applied to a graph rather than a flat list — and deliberately
/// *across* projects, since docs/05 asks for it "regardless of which `LoopGraph` they
/// belong to". A human with four projects open has one attention queue, not four.
public enum AttentionRollup {
  /// Worst first, then oldest first within a reason — a loop that has been failing for
  /// an hour outranks one that failed a moment ago, because it's the one that has been
  /// ignored longest.
  public static func items(across graphs: [LoopGraph]) -> [AttentionItem] {
    var items: [(item: AttentionItem, createdAt: Date)] = []
    for graph in graphs {
      for node in graph.nodes {
        guard let reason = reason(for: node) else { continue }
        items.append(
          (
            AttentionItem(
              nodeID: node.id, nodeTitle: node.title, projectPath: graph.project.path,
              projectName: graph.project.name, reason: reason, createdAt: node.createdAt),
            node.createdAt
          ))
      }
    }
    return
      items
      .sorted {
        $0.item.reason == $1.item.reason
          ? $0.createdAt < $1.createdAt
          : $0.item.reason < $1.item.reason
      }
      .map(\.item)
  }

  /// A node's attention reason, or `nil` when it wants nothing.
  ///
  /// **Read off `displayState`, and that is what makes `.awaitingInput` reachable at all.**
  /// Against raw `state` this switch could only ever fire for `.failed` and `.stalled`:
  /// nothing writes `.awaitingInput` into `state` — by design, since a loop whose agent
  /// asked a question is still the running node its downstream edges wait on — so the
  /// everyday case the whole queue exists for, an agent stopped mid-work asking a human
  /// something, never once reached it. That is where the reading lives; see
  /// `LoopNode.displayState`.
  ///
  /// `.blocked` counts only when the block can never clear on its own. A node waiting on
  /// an upstream that is still running is working as designed; one waiting on an
  /// upstream that already failed, stalled, or resolved without firing this edge is
  /// stuck, and that is worth a human's time. Reporting every blocked node would bury
  /// the real problems under the normal ones — which is the failure mode this rollup
  /// exists to prevent.
  static func reason(for node: LoopNode) -> AttentionReason? {
    switch node.displayState {
    case .failed: return .failed
    case .stalled: return .stalled
    case .awaitingInput: return .awaitingInput
    // `.stopped` is deliberately not here: a human turned it off, so telling them it
    // needs their attention is telling them about their own decision.
    case .blocked, .idle, .running, .succeeded, .stopped: return nil
    }
  }

  /// Blocked nodes whose upstream can no longer deliver. Needs the graph, not just the
  /// node, which is why it's separate from `reason(for:)`.
  static func strandedNodeIDs(in graph: LoopGraph) -> Set<UUID> {
    var stranded: Set<UUID> = []
    for node in graph.nodes where node.state == .blocked {
      let inbound = graph.edges.filter { $0.to == node.id && $0.kind.blocksTarget && !$0.fired }
      // Every remaining hope has already had its chance and didn't fire.
      let anyStillPossible = inbound.contains { edge in
        guard let source = graph.nodes[id: edge.from] else { return false }
        return !source.isResolved
      }
      if !inbound.isEmpty && !anyStillPossible { stranded.insert(node.id) }
    }
    return stranded
  }

  /// The full rollup, including stranded-blocked nodes that `reason(for:)` alone can't
  /// identify.
  public static func fullRollup(across graphs: [LoopGraph]) -> [AttentionItem] {
    var items = self.items(across: graphs)
    for graph in graphs {
      for nodeID in strandedNodeIDs(in: graph) {
        guard let node = graph.nodes[id: nodeID] else { continue }
        items.append(
          AttentionItem(
            nodeID: node.id, nodeTitle: node.title, projectPath: graph.project.path,
            projectName: graph.project.name, reason: .blocked, createdAt: node.createdAt))
      }
    }
    return items.sorted { $0.reason < $1.reason }
  }
}

extension LoopGraph {
  /// One rolled-up status for a whole graph, so a human doesn't have to open the canvas
  /// to know whether anything needs them (docs/05-orchestrator.md#monitoring-surface).
  /// Read off `displayState` for the same reason `AttentionRollup.reason(for:)` is: a
  /// session that is asking a human something is `.running` in the graph, so against raw
  /// `state` a folder full of loops waiting on answers summarised as "running".
  public var aggregateState: LoopState {
    if nodes.contains(where: { $0.displayState == .failed }) { return .failed }
    if nodes.contains(where: { $0.displayState == .stalled }) { return .stalled }
    if nodes.contains(where: { $0.displayState == .awaitingInput }) { return .awaitingInput }
    if nodes.contains(where: { $0.displayState == .running }) { return .running }
    if !nodes.isEmpty && nodes.allSatisfy({ $0.displayState == .succeeded }) { return .succeeded }
    if nodes.contains(where: { $0.displayState == .blocked }) { return .blocked }
    return .idle
  }
}
