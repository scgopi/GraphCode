import Foundation

/// One node in a graph of loops: a unit of agentic work with a well-defined hand-off
/// contract, running inside a real CLI session. See docs/02-graph-of-loops.md.
///
/// Phase 1 scope: turn-based only, no `LoopEdge`/`LoopGraph` yet — a node stands alone.
/// `checkDescription` stands in for the richer `HandoffSpec` the full taxonomy needs;
/// it's replaced once goal-based/time-based nodes get their own payload types.
public struct LoopNode: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var loopType: LoopType
  /// What a human verifies each turn before the loop continues — see
  /// docs/01-loop-taxonomy.md#turn-based--you-hand-off-the-check.
  public var checkDescription: String
  public var backend: CLISessionBackendKind
  public var worktreeBinding: WorktreeRef?
  public var state: LoopState
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    loopType: LoopType = .turnBased,
    checkDescription: String,
    backend: CLISessionBackendKind = .claudeCode,
    worktreeBinding: WorktreeRef? = nil,
    state: LoopState = .idle,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.loopType = loopType
    self.checkDescription = checkDescription
    self.backend = backend
    self.worktreeBinding = worktreeBinding
    self.state = state
    self.createdAt = createdAt
  }
}
