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
  /// The stop condition a goal-based node was handed (`.goalBased`) — see
  /// docs/01-loop-taxonomy.md#goal-based--you-hand-off-the-stop-condition.
  public var goal: GoalSpec?
  public var backend: CLISessionBackendKind
  /// `nil` means "whatever the orchestrator's routing policy says for this loop type" —
  /// a human can pin it per node (docs/06-ux-terminals.md#node-configuration-panel), and
  /// the absence of a pin is meaningfully different from a pin that happens to match.
  public var modelTier: ModelTier?
  public var worktreeBinding: WorktreeRef?
  /// A `.proactive` node's own graph — "a proactive node is the orchestrator running a
  /// graph inside a graph" (docs/05-orchestrator.md#responsibilities item 6). The
  /// recursion is finite because it goes through `IdentifiedArrayOf`, whose storage is
  /// heap-allocated.
  public var subGraph: LoopGraph?
  /// Where a `.proactive` node is in the pilot-before-arm flow. Meaningless for other
  /// loop types, which have nothing to fan out.
  public var pilotState: PilotState
  /// What the backend has reported spending on this loop, if anything. Never estimated —
  /// see `UsageSample`.
  public var usage: UsageSample?
  public var state: LoopState
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    loopType: LoopType = .turnBased,
    checkDescription: String? = nil,
    triggerPrompt: String? = nil,
    goal: GoalSpec? = nil,
    backend: CLISessionBackendKind = .claudeCode,
    modelTier: ModelTier? = nil,
    worktreeBinding: WorktreeRef? = nil,
    subGraph: LoopGraph? = nil,
    pilotState: PilotState = .notPiloted,
    usage: UsageSample? = nil,
    state: LoopState = .idle,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.loopType = loopType
    self.checkDescription = checkDescription
    self.triggerPrompt = triggerPrompt
    self.goal = goal
    self.backend = backend
    self.modelTier = modelTier
    self.worktreeBinding = worktreeBinding
    self.subGraph = subGraph
    self.pilotState = pilotState
    self.usage = usage
    self.state = state
    self.createdAt = createdAt
  }

  /// The opening prompt this node's `zmx` session should run, or `nil` for a node whose
  /// session is just a shell a human drives. One place so `ZmxSessionLauncher` (daemon)
  /// and `LoopWorkspaceView` (app) can never disagree about what a loop starts with.
  public var sessionPrompt: String? {
    switch loopType {
    case .timeBased: return triggerPrompt
    case .goalBased: return goal?.sessionPrompt
    case .turnBased, .proactive: return nil
    }
  }

  /// The tier this node actually runs on: the human's pin if there is one, otherwise
  /// the orchestrator's routing policy for its loop type.
  public var effectiveModelTier: ModelTier {
    modelTier ?? loopType.defaultModelTier
  }

  /// Loops `graphcoded` is responsible for keeping alive across its own restarts,
  /// because nothing else would restart them — as opposed to a turn-based node, which a
  /// human opening is what starts.
  public var runsUnattended: Bool {
    loopType == .timeBased || loopType == .goalBased
  }

  /// Whether this node has finished for good. Used to stop a resolved goal from being
  /// re-pursued when its project is reloaded.
  public var isResolved: Bool {
    switch state {
    case .succeeded, .failed, .stalled, .stopped: return true
    case .idle, .running, .awaitingInput, .blocked: return false
    }
  }

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case id, title, loopType, checkDescription, triggerPrompt, goal, backend, modelTier
    case worktreeBinding, subGraph, pilotState, usage, state, createdAt
  }

  /// Hand-written for the same reason `LoopEdge`'s is: `ProjectPersistence.loadGraph`
  /// turns any decode failure into "no saved graph", so a field added after a project
  /// was last saved has to fall back to a default rather than take the whole graph down.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
    loopType = try container.decodeIfPresent(LoopType.self, forKey: .loopType) ?? .turnBased
    checkDescription = try container.decodeIfPresent(String.self, forKey: .checkDescription)
    triggerPrompt = try container.decodeIfPresent(String.self, forKey: .triggerPrompt)
    goal = try container.decodeIfPresent(GoalSpec.self, forKey: .goal)
    backend =
      try container.decodeIfPresent(CLISessionBackendKind.self, forKey: .backend) ?? .claudeCode
    modelTier = try container.decodeIfPresent(ModelTier.self, forKey: .modelTier)
    worktreeBinding = try container.decodeIfPresent(WorktreeRef.self, forKey: .worktreeBinding)
    subGraph = try container.decodeIfPresent(LoopGraph.self, forKey: .subGraph)
    pilotState = try container.decodeIfPresent(PilotState.self, forKey: .pilotState) ?? .notPiloted
    usage = try container.decodeIfPresent(UsageSample.self, forKey: .usage)
    state = try container.decodeIfPresent(LoopState.self, forKey: .state) ?? .idle
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}
