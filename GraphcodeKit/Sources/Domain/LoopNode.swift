import Foundation

/// One node in a graph of loops: a unit of agentic work with a well-defined hand-off
/// contract, running inside a real CLI session. See docs/02-graph-of-loops.md.
///
/// `checkDescription`/`triggerPrompt` stand in for the richer `HandoffSpec`
/// the full taxonomy describes — plain fields for now, one per loop type actually
/// wired up (turn-based, time-based), rather than a whole payload-type hierarchy for
/// types (`.goalBased`, `.composite`) nothing constructs yet.
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
  /// `.turnBased`: what the session is actually asked to do.
  ///
  /// Without this the type had no task field at all — a turn-based session opened
  /// knowing it should stop after each turn and what the human would be checking, but
  /// never what work to start. The criterion is the hand-off; this is the job.
  public var firstInstruction: String?
  /// `.turnBased`: pause only where it would change something, rather than after every
  /// turn. Reads and searches run through.
  ///
  /// Stored rather than folded into the prompt at creation, so a loop can say later what
  /// it agreed to — and so the prompt stays derivable from the node instead of being a
  /// sentence nobody can re-read.
  public var pausesBeforeWritesOnly: Bool
  /// The stop condition a goal-based node was handed (`.goalBased`) — see
  /// docs/01-loop-taxonomy.md#goal-based--you-hand-off-the-stop-condition.
  public var goal: GoalSpec?
  public var backend: CLISessionBackendKind
  /// `nil` means "whatever the orchestrator's routing policy says for this loop type" —
  /// a human can pin it per node (docs/06-ux-terminals.md#node-configuration-panel), and
  /// the absence of a pin is meaningfully different from a pin that happens to match.
  public var modelTier: ModelTier?
  public var worktreeBinding: WorktreeRef?
  /// A `.composite` node's own graph — "a proactive node is the orchestrator running a
  /// graph inside a graph" (docs/05-orchestrator.md#responsibilities item 6). The
  /// recursion is finite because it goes through `IdentifiedArrayOf`, whose storage is
  /// heap-allocated.
  public var subGraph: LoopGraph?
  /// Where a `.composite` node is in the pilot-before-arm flow. Meaningless for other
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
  /// What the session is doing right now, as last read off its own label store
  /// (`PresenceHooks` writes it, `ZmxSessionLauncher.presence` reads it).
  ///
  /// Deliberately alongside `state` rather than folded into it — see `Presence` for why
  /// the two are different questions. `state` is what the graph believes about a loop's
  /// place in the work; this is what its session is doing this second. A goal loop stays
  /// `.running` from creation until something resolves it, so it is this field, and only
  /// this field, that can tell a card mid-work from a card whose agent finished its turn
  /// half an hour ago.
  ///
  /// `nil` until something reports one — a backend with no hooks, a session that hasn't
  /// been polled yet, or `zmx` not installed. Every surface treats that as "no better
  /// information than `state`", which is exactly what shipped before this existed.
  public var presence: PresenceReading?
  /// Whether this node has outgoing fired edges to unresolved nodes. Set by
  /// `GraphStore.refreshPresence` alongside `presence` — same lifecycle, same
  /// non-persistence guarantee. Drives the `.waiting` derivation in `displayState`.
  public var hasActiveDependents: Bool = false
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
    firstInstruction: String? = nil,
    pausesBeforeWritesOnly: Bool = false,
    goal: GoalSpec? = nil,
    backend: CLISessionBackendKind = .claudeCode,
    modelTier: ModelTier? = nil,
    worktreeBinding: WorktreeRef? = nil,
    subGraph: LoopGraph? = nil,
    pilotState: PilotState = .notPiloted,
    usage: UsageSample? = nil,
    activity: String? = nil,
    presence: PresenceReading? = nil,
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
    self.firstInstruction = firstInstruction
    self.pausesBeforeWritesOnly = pausesBeforeWritesOnly
    self.goal = goal
    self.backend = backend
    self.modelTier = modelTier
    self.worktreeBinding = worktreeBinding
    self.subGraph = subGraph
    self.pilotState = pilotState
    self.usage = usage
    self.activity = activity
    self.presence = presence
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
    case .turnBased:
      return Self.turnBasedPrompt(
        instruction: firstInstruction, check: checkDescription,
        beforeWritesOnly: pausesBeforeWritesOnly)
    case .composite: return nil
    }
  }

  /// What a turn-based session opens with: work in turns, stop for review, and here is
  /// what the review is against.
  ///
  /// Phrased to ask for a pause rather than a report — the hand-off this type names is the
  /// *check*, and a session that runs to completion and then summarises has already made
  /// every decision the check existed to gate.
  static func turnBasedPrompt(
    instruction: String?, check: String?, beforeWritesOnly: Bool = false
  ) -> String? {
    let task = instruction?.trimmingCharacters(in: .whitespaces) ?? ""
    let pause =
      beforeWritesOnly
      ? """
      Work in turns. Stop for a human's review before anything that changes files or \
      state; reading, searching and reasoning can run straight through.
      """
      : """
      Work in turns, stopping after each one so a human can review it before you continue \
      rather than running to completion on your own.
      """
    let criterion = check?.trimmingCharacters(in: .whitespaces) ?? ""
    // The criterion is optional; the *shape* of the loop is not. A turn-based session with
    // nobody's stated criterion should still stop for review — the human is the hand-off
    // whether or not they wrote down in advance what they would be looking for.
    var parts = task.isEmpty ? [] : [task]
    parts.append(pause)
    if !criterion.isEmpty { parts.append("Each turn is verified against this: \(criterion)") }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
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

  /// The state a surface should show, which is `state` corrected by what the session is
  /// actually doing.
  ///
  /// Only `.running` is ever corrected, and that is the whole point. Every other state is
  /// a fact about the loop's place in the graph that no session reading can improve on: a
  /// `.blocked` node is waiting on an edge whether or not its session is alive, and a
  /// `.succeeded` one is finished whatever is still running in its pane. `.running` is the
  /// odd one out because it is set at *creation* and cleared only by resolution — so
  /// between those two moments it is a claim about the present tense that nothing was
  /// checking. A goal loop whose agent answered and stopped reads RUNNING, pulsing, for
  /// as long as it takes a human to notice and stop it.
  ///
  /// Deliberately derived rather than written back into `state`. `state` is what the graph
  /// believes, and edge firing, `MessageBus.deliverability` and resolution all read it; a
  /// loop that went quiet for a minute has not stopped being the running node its
  /// downstream edges are waiting on. This is the presentation of that fact, not a
  /// revision of it.
  ///
  /// A backend that reports nothing leaves `presence` nil and this returns `state`
  /// untouched, which is exactly the behaviour every surface had before presence existed.
  public var displayState: LoopState {
    guard state == .running, let presence = presence?.presence else { return state }
    switch presence {
    case .busy: return .running
    case .idle, .absent: return hasActiveDependents ? .waiting : .idle
    // The combination `Presence` was written for: running in the graph, waiting on a
    // human in its session.
    case .awaitingInput: return .awaitingInput
    // A probe that failed in transport observed nothing — the graph's own belief is
    // the only honest thing left to show, exactly as if no reading existed.
    case .unknown: return state
    }
  }

  /// Whether this node has finished for good. Used to stop a resolved goal from being
  /// re-pursued when its project is reloaded.
  public var isResolved: Bool {
    switch state {
    case .succeeded, .failed, .stalled, .stopped: return true
    case .idle, .running, .awaitingInput, .blocked, .waiting: return false
    }
  }

  // MARK: - Coding

  private enum CodingKeys: String, CodingKey {
    case id, title, loopType, checkDescription, triggerPrompt, goal, backend, modelTier
    case worktreeBinding, subGraph, pilotState, usage, metricHistory, createdBy
    case state, createdAt, activity, presence, firstInstruction, pausesBeforeWritesOnly
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
    firstInstruction = try container.decodeIfPresent(String.self, forKey: .firstInstruction)
    // Absent from graphs saved before the field existed. Those loops paused after every
    // turn, which is what `false` says.
    pausesBeforeWritesOnly =
      try container.decodeIfPresent(Bool.self, forKey: .pausesBeforeWritesOnly) ?? false
    goal = try container.decodeIfPresent(GoalSpec.self, forKey: .goal)
    backend =
      try container.decodeIfPresent(CLISessionBackendKind.self, forKey: .backend) ?? .claudeCode
    modelTier = try container.decodeIfPresent(ModelTier.self, forKey: .modelTier)
    worktreeBinding = try container.decodeIfPresent(WorktreeRef.self, forKey: .worktreeBinding)
    subGraph = try container.decodeIfPresent(LoopGraph.self, forKey: .subGraph)
    pilotState = try container.decodeIfPresent(PilotState.self, forKey: .pilotState) ?? .notPiloted
    usage = try container.decodeIfPresent(UsageSample.self, forKey: .usage)
    activity = try container.decodeIfPresent(String.self, forKey: .activity)
    presence = try container.decodeIfPresent(PresenceReading.self, forKey: .presence)
    metricHistory =
      try container.decodeIfPresent([MetricSample].self, forKey: .metricHistory) ?? []
    createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
    state = try container.decodeIfPresent(LoopState.self, forKey: .state) ?? .idle
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}
