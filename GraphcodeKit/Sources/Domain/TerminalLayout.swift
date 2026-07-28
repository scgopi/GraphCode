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

/// One tab in a loop's terminal workspace — at most one split, per the deliberately
/// simple (non-recursive) split model this phase scoped to. `secondary == nil` means
/// the tab shows just `primary`.
public struct TabLayout: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var primary: SurfaceRef
  public var secondary: SurfaceRef?
  public var splitDirection: SplitDirection

  public init(
    id: UUID = UUID(),
    primary: SurfaceRef,
    secondary: SurfaceRef? = nil,
    splitDirection: SplitDirection = .horizontal
  ) {
    self.id = id
    self.primary = primary
    self.secondary = secondary
    self.splitDirection = splitDirection
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
