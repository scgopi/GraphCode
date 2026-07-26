import Foundation

/// One node in a graph of loops: a unit of agentic work with a well-defined hand-off
/// contract, running inside a real CLI session. See docs/02-graph-of-loops.md.
///
/// `checkDescription`/`triggerPrompt` stand in for the richer `HandoffSpec`
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
  /// The initial prompt a time-based node's session starts with, passed through to the
  /// backend verbatim — see docs/01-loop-taxonomy.md#time-based--you-hand-off-the-trigger.
  ///
  /// graphcode deliberately holds no interval of its own: the recurrence lives *inside*
  /// the session, expressed in this prompt via the backend's own looping skill (`/loop`,
  /// `/schedule`). That's what makes a time-based loop an ordinary interactive session a
  /// human can attach to and steer mid-run, instead of something a scheduler outside it
  /// fires headlessly. It also means cron and self-pacing work without graphcode
  /// modelling either, and nothing here inspects or validates the prompt.
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
    self.triggerPrompt = triggerPrompt
    self.backend = backend
    self.worktreeBinding = worktreeBinding
    self.state = state
    self.createdAt = createdAt
  }
}
