import Foundation

/// An optional git worktree binding for a `LoopNode` — deliberately minimal: only what
/// `GitClient` needs to create, list, and remove a worktree. See
/// docs/02-graph-of-loops.md.
public struct WorktreeRef: Identifiable, Codable, Equatable, Hashable, Sendable {
  public let id: String
  public var repositoryPath: String
  public var worktreePath: String
  public var branch: String

  public init(id: String, repositoryPath: String, worktreePath: String, branch: String) {
    self.id = id
    self.repositoryPath = repositoryPath
    self.worktreePath = worktreePath
    self.branch = branch
  }

  /// What to call this worktree in a row or an error line. A detached worktree has no
  /// branch to name, so its folder stands in.
  public var displayName: String {
    branch.isEmpty ? (worktreePath as NSString).lastPathComponent : branch
  }
}
