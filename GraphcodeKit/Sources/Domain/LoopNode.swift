import Foundation

/// One node in a graph of loops: a unit of agentic work with a well-defined hand-off
/// contract, running inside a real CLI session. See docs/02-graph-of-loops.md.
///
/// `checkDescription`/`triggerIntervalSeconds` stand in for the richer `HandoffSpec`
/// the full taxonomy describes — plain fields for now, one per loop type actually
/// wired up (turn-based, time-based), rather than a whole payload-type hierarchy for
/// types (`.goalBased`, `.proactive`) nothing constructs yet.
public struct LoopNode: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var loopType: LoopType
  /// What a human verifies each turn before the loop continues (`.turnBased`) — see
  /// docs/01-loop-taxonomy.md#turn-based--you-hand-off-the-check.
  public var checkDescription: String?
  /// How often `graphcoded` re-fires this node's prompt (`.timeBased`) — see
  /// docs/01-loop-taxonomy.md#time-based--you-hand-off-the-trigger.
  public var triggerIntervalSeconds: TimeInterval?
  /// What runs each time the trigger fires (`.timeBased`). Launched non-interactively
  /// (`claude -p`, not a bare interactive session) since there's no human present to
  /// hold a conversation with — a time-based node needs an actual task to run to
  /// completion, not just a clock.
  public var triggerPrompt: String?
  public var backend: CLISessionBackendKind
  public var worktreeBinding: WorktreeRef?
  public var state: LoopState
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    loopType: LoopType = .turnBased,
    checkDescription: String? = nil,
    triggerIntervalSeconds: TimeInterval? = nil,
    triggerPrompt: String? = nil,
    backend: CLISessionBackendKind = .claudeCode,
    worktreeBinding: WorktreeRef? = nil,
    state: LoopState = .idle,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.loopType = loopType
    self.checkDescription = checkDescription
    self.triggerIntervalSeconds = triggerIntervalSeconds
    self.triggerPrompt = triggerPrompt
    self.backend = backend
    self.worktreeBinding = worktreeBinding
    self.state = state
    self.createdAt = createdAt
  }
}
