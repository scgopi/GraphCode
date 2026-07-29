import Foundation
import IdentifiedCollections

/// Which zmx session backs one terminal surface, and what it launches — see
/// docs/07-roadmap.md's per-loop terminal workspace follow-up. `id` doubles as the
/// zmx session name's unique suffix (`"graphcode-\(id.uuidString)"`), so there's no
/// separate identity to keep in sync.
public struct SurfaceRef: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  /// True only for a loop's original surface — its actual Claude Code agent session.
  /// Every surface added afterward (a new tab, a split) starts a plain shell instead;
  /// the human decides what to run there.
  public var launchesClaudeCode: Bool

  public init(id: UUID, launchesClaudeCode: Bool) {
    self.id = id
    self.launchesClaudeCode = launchesClaudeCode
  }

  public var zmxSessionName: String { "graphcode-\(id.uuidString)" }

  public static let zmxSessionPrefix = "graphcode-"

  /// Which node a `zmx` session name belongs to — the inverse of `zmxSessionName`.
  ///
  /// This is what lets a running loop identify *itself*: `zmx` injects `ZMX_SESSION` into
  /// every session's environment, and graphcode names its sessions after the node id. So
  /// the `graphcode` CLI, invoked from inside a loop, can work out which loop invoked it
  /// without the agent being told to pass anything.
  public static func nodeID(fromZmxSessionName name: String) -> UUID? {
    guard name.hasPrefix(zmxSessionPrefix) else { return nil }
    return UUID(uuidString: String(name.dropFirst(zmxSessionPrefix.count)))
  }
}

public enum SplitDirection: Codable, Equatable, Sendable {
  case horizontal
  case vertical
}

/// How one tab's panes are arranged: a leaf is a single terminal, a split is two or more
/// children laid out along one axis, and a child may itself be a split.
///
/// A tab used to hold a `primary` and one optional `secondary`, which is why ⌘D worked
/// exactly once per tab and then went quiet. Recursion is what a terminal's split actually
/// is — splitting a pane replaces *that pane* with a row of two, wherever it sits — and it
/// is what lets ⌘D, ⌘⇧D, ⌘D again build the layout you asked for instead of the first
/// third of it.
public indirect enum SplitNode: Equatable, Sendable {
  case leaf(SurfaceRef)
  /// Always two or more children — `removing(_:)` collapses a container the moment it
  /// would be left with one, so "a split with a single pane in it" never exists.
  case split(direction: SplitDirection, children: [SplitNode])
}

extension SplitNode {
  /// Every pane in this subtree, in the order they appear on screen (left to right, top to
  /// bottom). That ordering is what makes "focus the pane that took over the space" a
  /// plain index step after a close.
  public var surfaces: [SurfaceRef] {
    switch self {
    case .leaf(let surface): [surface]
    case .split(_, let children): children.flatMap(\.surfaces)
    }
  }

  /// This subtree's first pane. Non-optional because a node always bottoms out in a leaf —
  /// which is what lets `TabLayout.primary` stay non-optional too.
  public var firstSurface: SurfaceRef {
    switch self {
    case .leaf(let surface): surface
    case .split(_, let children): children[0].firstSurface
    }
  }

  /// Whether this tab is showing more than one pane.
  public var isSplit: Bool {
    if case .split = self { true } else { false }
  }

  /// Splits the pane named by `targetID`, putting `addition` immediately after it. Returns
  /// the tree unchanged if no pane here has that id.
  public func splitting(
    _ targetID: UUID, with addition: SurfaceRef, direction: SplitDirection
  ) -> SplitNode {
    switch self {
    case .leaf(let surface):
      guard surface.id == targetID else { return self }
      return .split(direction: direction, children: [.leaf(surface), .leaf(addition)])

    case .split(let existing, let children):
      // A pane split again along the axis it already sits on joins its siblings instead of
      // nesting inside its own half of the row. That is what makes ⌘D three times give
      // three equal panes rather than 1/2, 1/4, 1/4 — and it's why no split ever ends up
      // directly inside another of the same direction.
      if existing == direction,
        let index = children.firstIndex(where: { $0.leafSurfaceID == targetID })
      {
        var siblings = children
        siblings.insert(.leaf(addition), at: index + 1)
        return .split(direction: existing, children: siblings)
      }
      return .split(
        direction: existing,
        children: children.map { $0.splitting(targetID, with: addition, direction: direction) })
    }
  }

  /// Drops one pane. `nil` means the tree was just that pane — the caller's tab has nothing
  /// left to show and should close.
  public func removing(_ surfaceID: UUID) -> SplitNode? {
    switch self {
    case .leaf(let surface):
      return surface.id == surfaceID ? nil : self

    case .split(let direction, let children):
      let remaining = children.compactMap { $0.removing(surfaceID) }
      guard let survivor = remaining.first else { return nil }
      // Down to one child, a container stops being a split: the survivor takes the whole
      // space the row occupied, however deep it was nested.
      guard remaining.count > 1 else { return survivor }
      return .split(direction: direction, children: remaining)
    }
  }

  /// This node's own surface, if it is a leaf — how a container recognises which of its
  /// direct children is the pane being split.
  private var leafSurfaceID: UUID? {
    if case .leaf(let surface) = self { surface.id } else { nil }
  }
}

extension SplitNode: Identifiable {
  /// A node is identified by its first pane, which is unique across the whole tree (surface
  /// ids are) and stable for as long as that pane exists. `ForEach` needs sibling rows to
  /// be told apart by something that isn't their index, so removing a pane doesn't look
  /// like every pane after it changing into its neighbour.
  public var id: UUID { firstSurface.id }
}

extension SplitNode: Codable {
  private enum CodingKeys: String, CodingKey {
    case surface
    case direction
    case children
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let surface = try container.decodeIfPresent(SurfaceRef.self, forKey: .surface) {
      self = .leaf(surface)
      return
    }
    self = .split(
      direction: try container.decode(SplitDirection.self, forKey: .direction),
      children: try container.decode([SplitNode].self, forKey: .children))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .leaf(let surface):
      try container.encode(surface, forKey: .surface)
    case .split(let direction, let children):
      try container.encode(direction, forKey: .direction)
      try container.encode(children, forKey: .children)
    }
  }
}

/// One tab in a loop's terminal workspace, and the panes it is showing.
public struct TabLayout: Equatable, Sendable, Identifiable {
  public var id: UUID
  /// This tab's panes — a lone leaf until the first split, a tree of any depth after that.
  public var root: SplitNode

  /// Which of this tab's panes has the keyboard.
  ///
  /// A split tab has several live terminals and only one of them can be typed into, so
  /// something has to say which — and it has to be *this*, not AppKit's first responder.
  /// Both are real, and when they disagree you get the failure this fixes: every pane
  /// drawing a filled cursor, with no way to tell which one your keystrokes are going to.
  /// It is also which pane ⌘D splits, so a third pane lands beside the one you were
  /// working in rather than always beside the first. The view
  /// derives everything from this value (cursor, dimming, first responder), so there is
  /// one answer rather than two that have to be kept in step.
  ///
  /// Optional because it is also the "not decided yet" state: a layout persisted before
  /// this existed decodes with no value, and nothing should be dimmed until a pane has
  /// actually been chosen. Read it through `focusedSurface`, which resolves both that case
  /// and an id left pointing at a pane that has since been closed.
  public var focusedSurfaceID: UUID?

  public init(id: UUID = UUID(), root: SplitNode, focusedSurfaceID: UUID? = nil) {
    self.id = id
    self.root = root
    self.focusedSurfaceID = focusedSurfaceID
  }

  /// A tab that starts as a single pane, which is how every tab starts.
  public init(id: UUID = UUID(), primary: SurfaceRef, focusedSurfaceID: UUID? = nil) {
    self.init(id: id, root: .leaf(primary), focusedSurfaceID: focusedSurfaceID)
  }

  /// This tab's first pane — for the tab a loop was opened in, its Claude Code session.
  /// Splitting and closing rearrange the tree around it, so this is a position rather than
  /// a fixed surface: whatever is leftmost/topmost now.
  public var primary: SurfaceRef { root.firstSurface }

  /// Every pane in this tab, in on-screen order.
  public var surfaces: [SurfaceRef] { root.surfaces }

  /// Whether this tab is showing more than one pane.
  public var isSplit: Bool { root.isSplit }

  /// The pane with the keyboard, falling back to `primary`.
  ///
  /// Self-healing rather than trusting the stored id: closing a pane can leave
  /// `focusedSurfaceID` naming one that no longer exists — which would leave *no* pane
  /// focused, so the tab would take no keystrokes at all. Resolving against the panes that
  /// are actually here means the worst case is focus landing on `primary`, never nowhere.
  public var focusedSurface: SurfaceRef {
    guard let focusedSurfaceID,
      let focused = surfaces.first(where: { $0.id == focusedSurfaceID })
    else { return primary }
    return focused
  }
}

extension TabLayout: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case root
    case focusedSurfaceID
    /// The pre-tree shape: one pane, one optional second, and the axis between them.
    case primary
    case secondary
    case splitDirection
  }

  /// Reads both shapes, because a layout persisted by an earlier build is on disk for
  /// anyone already using graphcode — and a tab that failed to decode is a tab whose
  /// terminals are still running with nothing on screen pointing at them.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    focusedSurfaceID = try container.decodeIfPresent(UUID.self, forKey: .focusedSurfaceID)

    if let root = try container.decodeIfPresent(SplitNode.self, forKey: .root) {
      self.root = root
      return
    }
    let primary = try container.decode(SurfaceRef.self, forKey: .primary)
    guard let secondary = try container.decodeIfPresent(SurfaceRef.self, forKey: .secondary)
    else {
      root = .leaf(primary)
      return
    }
    let direction =
      try container.decodeIfPresent(SplitDirection.self, forKey: .splitDirection) ?? .horizontal
    root = .split(direction: direction, children: [.leaf(primary), .leaf(secondary)])
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(root, forKey: .root)
    try container.encodeIfPresent(focusedSurfaceID, forKey: .focusedSurfaceID)
  }
}

/// A loop's whole terminal workspace: its tabs, and which one is showing. Persisted by
/// `TerminalLayoutStore` so it looks exactly the same the next time this loop is
/// opened — including after the app quits, since every surface's actual content lives
/// in its own long-running `zmx` session, not in this layout.
public struct TerminalLayout: Codable, Equatable, Sendable {
  public var tabs: IdentifiedArrayOf<TabLayout>
  public var selectedTabID: UUID

  public init(tabs: IdentifiedArrayOf<TabLayout>, selectedTabID: UUID) {
    self.tabs = tabs
    self.selectedTabID = selectedTabID
  }

  /// A brand-new loop's starting workspace: one tab, one surface, launching Claude
  /// Code — and that surface's id is the node's own id, not a fresh one, so it reuses
  /// exactly the zmx session name graphcode has always used for a loop's terminal.
  /// Already-running sessions from before per-loop workspaces existed aren't orphaned.
  public static func defaultLayout(forNode nodeID: UUID) -> TerminalLayout {
    let tab = TabLayout(primary: SurfaceRef(id: nodeID, launchesClaudeCode: true))
    return TerminalLayout(tabs: [tab], selectedTabID: tab.id)
  }
}
