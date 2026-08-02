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
  /// docs/01-loop-taxonomy.md#turn-based--you-hand-off-the-check. Surfaced as "Verify each
  /// turn"; the stored name is unchanged so no saved graph loses what it holds.
  ///
  /// Optional. The hand-off this type names is a human watching the work, and that human
  /// is there whether or not they wrote down in advance what they would be looking for —
  /// see `NodeDraft.isValid`. Without one the session is still told to stop after each
  /// turn for review, just not what the review is against.
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
  /// The last thing the session said it was doing — `"editing UsageReport.swift"`.
  ///
  /// Reported, never inferred, by exactly the mechanism `presence` and `usage` use: a
  /// backend lifecycle hook writing `zmx set "$ZMX_SESSION" activity=…` into the
  /// session's own label store. graphcode cannot see inside a running `claude`, and the
  /// alternative — scraping the terminal — would put a guess about what an agent is
  /// doing on the card next to the facts about what it has done.
  ///
  /// `nil` until something reports one, which is the common case, and the card's live
  /// line then says what the loop was *handed* instead. That fallback is honest and is
  /// what shipped before this field existed.
  public var activity: String?
  /// Recent readings of the goal's `metricCommand`, oldest first — one per cycle pass,
  /// capped at `LoopNode.maxMetricSamples` so per-poll persistence stays bounded. The
  /// full unbounded series lives in the node's memory log; this is the cache the canvas
  /// and the plateau rule read.
  public var metricHistory: [MetricSample]
  /// The loop that asked for this one, when a running session created it through the
  /// CLI (`NodeDraft.createdBy`). Recorded on the node, not just as the already-fired
  /// edge `linkToCreator` draws — a fired edge is indistinguishable from any drawn
  /// handoff, and custody has to be: stopping or deleting a parent takes its spawned
  /// descendants with it, while a drawn edge to a peer must never be caught in that.
  public let createdBy: UUID?
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
    activity: String? = nil,
    metricHistory: [MetricSample] = [],
    createdBy: UUID? = nil,
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
    self.activity = activity
    self.metricHistory = metricHistory
    self.createdBy = createdBy
    self.state = state
    self.createdAt = createdAt
  }

  /// How many metric samples the node itself carries — enough for a sparkline and any
  /// sane plateau bound, small enough that the per-mutation full-graph persist and
  /// broadcast stay cheap.
  public static let maxMetricSamples = 20

  /// The opening prompt this node's `zmx` session should run, or `nil` when there is
  /// nothing to say. One place so `ZmxSessionLauncher` (daemon) and `LoopWorkspaceView`
  /// (app) can never disagree about what a loop starts with.
  ///
  /// A turn-based node's criterion now travels with it. It used to be `nil` here, so what
  /// the human wrote reached nothing: it sat in the graph as metadata, the session opened
  /// knowing neither the criterion nor that it was a loop at all, and the human had to
  /// retype what they had already written. Handing it over costs one sentence.
  ///
  /// This does **not** make a turn-based loop start itself. `runsUnattended` is a separate
  /// rule and still excludes it, which is right: the type exists because a person is in the
  /// sequence, so a person opening it is what should begin it.
  public var sessionPrompt: String? {
    switch loopType {
    case .timeBased: return triggerPrompt
    case .goalBased: return goal?.sessionPrompt
    case .turnBased: return Self.turnBasedPrompt(check: checkDescription)
    case .proactive: return nil
    }
  }

  /// What a turn-based session opens with: work in turns, stop for review, and here is
  /// what the review is against.
  ///
  /// Phrased to ask for a pause rather than a report — the hand-off this type names is the
  /// *check*, and a session that runs to completion and then summarises has already made
  /// every decision the check existed to gate.
  static func turnBasedPrompt(check: String?) -> String? {
    let opening = """
      Work in turns, stopping after each one so a human can review it before you continue \
      rather than running to completion on your own.
      """
    let criterion = check?.trimmingCharacters(in: .whitespaces) ?? ""
    // The criterion is optional; the *shape* of the loop is not. A turn-based session with
    // nobody's stated criterion should still stop for review — the human is the hand-off
    // whether or not they wrote down in advance what they would be looking for.
    guard !criterion.isEmpty else { return opening }
    return "\(opening) Each turn is verified against this: \(criterion)"
  }

  /// The tier this node actually runs on: the human's pin if there is one, otherwise
  /// whatever `ModelTier.resolved` says — which, unless model auto-selection is switched
  /// on in Settings, is "don't pass a model at all and let the CLI's own default stand".
  public func effectiveModelTier(autoSelecting: Bool) -> ModelTier {
    ModelTier.resolved(pinned: modelTier, for: loopType, autoSelecting: autoSelecting)
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
    case worktreeBinding, subGraph, pilotState, usage, metricHistory, createdBy
    case state, createdAt
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
    metricHistory =
      try container.decodeIfPresent([MetricSample].self, forKey: .metricHistory) ?? []
    createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
    state = try container.decodeIfPresent(LoopState.self, forKey: .state) ?? .idle
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}
