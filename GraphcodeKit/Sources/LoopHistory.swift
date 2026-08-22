import Foundation

/// Somewhere the workspace pane has been — a loop in a project, or a quick chat. Both
/// open the same `LoopWorkspaceFeature`, so both belong in the same history; a Back that
/// silently stepped over the chat you were just in would be a Back that lies.
///
/// A loop carries its project path as well as its node id because the id alone cannot be
/// resolved: the app holds several projects at once and only the pair names a node.
public enum LoopVisit: Codable, Equatable, Sendable {
  case loop(projectPath: String, nodeID: UUID)
  case quickChat(id: UUID)

  public var nodeID: UUID {
    switch self {
    case .loop(_, let nodeID): return nodeID
    case .quickChat(let id): return id
    }
  }
}

/// A browser's back/forward stack over visited loops.
///
/// Deliberately a plain value with no knowledge of graphs, projects or the store: the
/// interesting behaviour here is the cursor arithmetic and the truncation rule, and both
/// are worth testing without an app around them. Resolving a visit against live state —
/// which projects are open, which nodes still exist — is the reducer's job, handed in as
/// a predicate so a stale entry can be stepped over rather than dead-ending the stack.
public struct LoopHistory: Codable, Equatable, Sendable {
  /// Oldest first. `cursor` indexes the entry currently on screen; `nil` means the
  /// history is empty or nothing from it is open.
  public private(set) var entries: [LoopVisit]
  public private(set) var cursor: Int?

  /// Long enough to cover any session's worth of moving around, short enough that the
  /// file stays trivial and a runaway loop of opens can't grow it without bound.
  static let limit = 50

  public init(entries: [LoopVisit] = [], cursor: Int? = nil) {
    self.entries = entries
    self.cursor = LoopHistory.clamp(cursor, to: entries)
  }

  /// A file written by a future build, or hand-edited, must not be able to put the
  /// cursor outside the entries it indexes.
  private static func clamp(_ cursor: Int?, to entries: [LoopVisit]) -> Int? {
    guard let cursor, !entries.isEmpty else { return nil }
    return min(max(cursor, 0), entries.count - 1)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let entries = try container.decodeIfPresent([LoopVisit].self, forKey: .entries) ?? []
    let cursor = try container.decodeIfPresent(Int.self, forKey: .cursor)
    self.init(entries: entries, cursor: cursor)
  }

  public var canGoBack: Bool { (cursor ?? 0) > 0 && !entries.isEmpty }
  public var canGoForward: Bool {
    guard let cursor else { return false }
    return cursor < entries.count - 1
  }

  public var current: LoopVisit? { cursor.map { entries[$0] } }

  /// Records an arrival the human chose — a tap, the jump palette, the attention rollup.
  ///
  /// Truncating everything ahead of the cursor is what makes this a browser rather than
  /// a ring: once you go back two loops and then open a third, the branch you left is
  /// gone, exactly as a browser discards forward history on a new navigation.
  ///
  /// Re-opening the loop already on screen is not a visit. It happens constantly —
  /// tapping the selected row, a rename re-selecting its own node — and each one would
  /// otherwise pad the stack with a step that goes nowhere.
  public mutating func record(_ visit: LoopVisit) {
    if current == visit { return }
    if let cursor, cursor < entries.count - 1 {
      entries.removeSubrange((cursor + 1)...)
    }
    entries.append(visit)
    if entries.count > LoopHistory.limit {
      entries.removeFirst(entries.count - LoopHistory.limit)
    }
    cursor = entries.count - 1
  }

  /// The nearest entry behind the cursor that `isResolvable` accepts, moving the cursor
  /// onto it. Entries that no longer resolve — a closed project, a deleted loop — are
  /// stepped over rather than removed: the same file is read again next launch, when the
  /// project may well be open, and a Back that deleted history on a transient miss would
  /// quietly erase it.
  ///
  /// When nothing behind the cursor resolves, the cursor does not move and `nil` comes
  /// back, so a dead tail cannot strand the user somewhere they never were.
  public mutating func back(where isResolvable: (LoopVisit) -> Bool) -> LoopVisit? {
    step(by: -1, where: isResolvable)
  }

  public mutating func forward(where isResolvable: (LoopVisit) -> Bool) -> LoopVisit? {
    step(by: +1, where: isResolvable)
  }

  private mutating func step(by offset: Int, where isResolvable: (LoopVisit) -> Bool)
    -> LoopVisit?
  {
    guard let cursor else { return nil }
    var candidate = cursor + offset
    while candidate >= 0 && candidate < entries.count {
      if isResolvable(entries[candidate]) {
        self.cursor = candidate
        return entries[candidate]
      }
      candidate += offset
    }
    return nil
  }
}
