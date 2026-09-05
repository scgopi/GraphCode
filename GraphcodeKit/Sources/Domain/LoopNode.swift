import MailroomKit
import Foundation

/// One node in a graph of loops: a unit of agentic work with a well-defined hand-off
/// contract, running inside a real CLI session. See docs/02-graph-of-loops.md.
///
/// `checkDescription`/`triggerPrompt` stand in for the richer `HandoffSpec`
/// the full taxonomy describes — plain fields for now, one per loop type actually
/// wired up (turn-based, time-based), rather than a whole payload-type hierarchy for
/// types (`.goalBased`, `.composite`) nothing constructs yet.
/// The template a loop still reads its brief from — see PROMPT_TEMPLATES.md
/// (New Designs v4) § Follow vs snapshot.
///
/// Only a **timed or composite** loop carries one: those re-read the template and
/// pick up its edits on their next run, so a fixed nightly brief doesn't need the
/// loop recreated. A Main, Goal or Turn loop snapshots its brief at creation and
/// never carries this — a running session cannot have its text swapped underneath
/// it. The node's own fields *are* the snapshot: if the template's file later
/// disappears, the loop keeps running on what it already had and says so.
public struct TemplateFollow: Codable, Equatable, Sendable {
  /// The template's id, not its filename — how a follow survives a rename or a
  /// move between home and a project.
  public var id: UUID
  public var name: String
  /// Set when a resolve could not find the file. The loop keeps its snapshot and
  /// the card warns rather than failing — the one difference between "the template
  /// changed" and "the template is gone".
  public var missing: Bool

  public init(id: UUID, name: String, missing: Bool = false) {
    self.id = id
    self.name = name
    self.missing = missing
  }
}

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
  /// `.timeBased`, experimental: the daemon drives this loop instead — a `[graphcode]`
  /// heartbeat typed into its session every interval (`GraphStore.deliverHeartbeat`),
  /// active only while `GraphcodeSettings.daemonHeartbeatEnabled` is on. When set,
  /// `triggerPrompt` is the bare task with no `/loop` directive: exactly one of the two
  /// cadence models drives a given loop, never both. `nil` — every loop that predates
  /// the experiment, and every loop whose author didn't opt in — means the prompt owns
  /// the cadence as it always has.
  public var heartbeatIntervalSeconds: Double?
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
  /// How many times the session has been restarted in place (`GraphCommand.restartNode`).
  /// The number means nothing; a *change* in it is the daemon's word that the old session
  /// is confirmed dead, which is what the app waits for before reattaching a pane. A pane
  /// attached any earlier joins the dying session and reads its exit as the loop resolving.
  public var sessionRestarts = 0
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
  /// The loop's narration — what it has been trying to do, in beats, bounded.
  ///
  /// `activity` is one phrase about one tool call and is replaced every time the call
  /// changes; this is the story around it, and the two are read off different halves of
  /// the same session. Kept on the node rather than in a side store because it is exactly
  /// as small as `metricHistory` (three beats and three pass lines, by construction — see
  /// `LoopSummary`) and every surface that wants it already has a node.
  ///
  /// `nil` until the summary producer is switched on in Settings, which is where it stays
  /// for anyone who never turns the experiment on.
  public var summary: LoopSummary?
  /// The same run, drawn — a Mermaid flowchart or a table, composed once per finished pass
  /// and rendered natively by the rail (`SummaryBoard`).
  ///
  /// Beside `summary` rather than inside it because the two are produced by different
  /// things at different prices: a beat is read off the transcript for nothing, every poll;
  /// a board is a model call, at a pass boundary, only if someone switched that on. Folding
  /// them together would mean a summary that costs money to merge.
  ///
  /// `nil` for anyone who never turns the experiment on, and cleared within a poll of it
  /// being turned off.
  public var board: SummaryBoard?
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
  /// Which template this loop's brief came from, for every type — pure attribution
  /// the card can show, never a live link. A snapshot loop keeps this and nothing
  /// more; a following one also carries `templateFollow`.
  public var createdFromTemplateID: UUID?
  /// The template a **timed or composite** loop still follows — see `TemplateFollow`
  /// for why only those two types do. `nil` for every snapshot loop.
  public var templateFollow: TemplateFollow?
  /// The newest Mailroom post this loop has read — `MailroomPost.id` of the last
  /// post a `graphcode mail inbox` showed it. `nil` has not synced yet and makes
  /// every post unread; the cursor only moves through sync, so a loop that ignores
  /// the board accrues nothing but a number, and a loop that died with unread mail
  /// finds it still waiting at the next wake.
  public var lastMailroomRead: Int?
  /// This loop's standing subscription to its project's Mailroom — set and cleared
  /// with `graphcode mail watch`. Non-nil means every matching post also gets
  /// delivered to this loop the way a `--follow-up` message is: typed into a live
  /// idle session, staged to a busy one's memory, waiting in the post itself for a
  /// loop that is gone. The post is the durable half; this is only the ding.
  public var mailroomWatch: MailroomWatch?
  /// Why the loop is `.stalled`, when the graph knows. A budget exhaustion and a stall
  /// bound both land in the same terminal state, and both wrote their reason only to
  /// the loop's memory log — every surface then showed a bare STALLED and a human had
  /// to open memory to learn whether to raise a number or kill a stuck loop. Set by
  /// `GraphStore` at the moment of the stall; `nil` for loops stalled before the field
  /// existed, and for stalls whose cause the graph had nothing to say about.
  public var stallReason: String?
  public var state: LoopState
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    loopType: LoopType = .turnBased,
    checkDescription: String? = nil,
    triggerPrompt: String? = nil,
    heartbeatIntervalSeconds: Double? = nil,
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
    summary: LoopSummary? = nil,
    board: SummaryBoard? = nil,
    presence: PresenceReading? = nil,
    metricHistory: [MetricSample] = [],
    createdBy: UUID? = nil,
    createdFromTemplateID: UUID? = nil,
    templateFollow: TemplateFollow? = nil,
    lastMailroomRead: Int? = nil,
    mailroomWatch: MailroomWatch? = nil,
    stallReason: String? = nil,
    state: LoopState = .idle,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.loopType = loopType
    self.checkDescription = checkDescription
    self.triggerPrompt = triggerPrompt
    self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
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
    self.summary = summary
    self.board = board
    self.presence = presence
    self.metricHistory = metricHistory
    self.createdBy = createdBy
    self.createdFromTemplateID = createdFromTemplateID
    self.templateFollow = templateFollow
    self.lastMailroomRead = lastMailroomRead
    self.mailroomWatch = mailroomWatch
    self.stallReason = stallReason
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
    case .sketch:
      // The starting note, when there is one. A blank note means the session opens
      // quiet and waits — asking nothing up front is what the type is for.
      let note = firstInstruction?.trimmingCharacters(in: .whitespaces) ?? ""
      return note.isEmpty ? nil : note
    case .timeBased:
      // Copilot's `/every` submits its first prompt only after the interval elapses, so
      // a directive-led opening armed correctly and then sat idle — and the typed
      // first-pass workaround raced the composer. The reliable channel is the opening
      // prompt itself, so for Copilot it carries both halves as prose: run the task
      // now, then arm your own `/every`. The session still owns the cadence; graphcode
      // holds no timer. Claude Code keeps the directive verbatim — its `/loop` runs the
      // first iteration itself.
      if backend == .copilotCLI, heartbeatIntervalSeconds == nil, let prompt = triggerPrompt,
        let recurrence = SessionPrompt.recurrence(of: prompt)
      {
        return "Run this task now: \(recurrence.task) Then schedule it to repeat with: "
          + "/every \(recurrence.interval) \(recurrence.task)"
      }
      if backend.capabilities.supportsDaemonRecurrence,
        let interval = effectiveHeartbeatInterval,
        interval.isFinite,
        interval > 0
      {
        let task = heartbeatTask ?? ""
        return "Run one pass of this task now: \(task) Then stay in the session — every "
          + "\(Int(interval))s you will receive a [graphcode] heartbeat message, and each "
          + "one is your cue to run the next pass. Do not schedule your own /loop, wakeup, "
          + "or cron for it — the orchestrator holds the timer."
      }
      guard let interval = heartbeatIntervalSeconds, interval.isFinite, interval > 0,
        let task = triggerPrompt
      else { return triggerPrompt }
      // The heartbeat counterpart of the /loop directive: the session is told who
      // holds the timer, so it neither schedules its own cadence (double-driving)
      // nor exits believing one pass was the whole job.
      return "Every \(Int(interval))s you will receive a [graphcode] heartbeat message. "
        + "Each one is your cue to run one pass of this task, then wait for the next: "
        + "\(task) Do not schedule your own /loop, wakeup, or cron for it — the "
        + "orchestrator holds the timer. Stay in the session between heartbeats."
    case .goalBased:
      return goal?.sessionPrompt(directive: backend.capabilities.goalDirective)
    case .turnBased:
      return Self.turnBasedPrompt(
        instruction: firstInstruction, check: checkDescription,
        beforeWritesOnly: pausesBeforeWritesOnly)
    case .composite: return nil
    }
  }

  public var effectiveHeartbeatInterval: Double? {
    if let interval = heartbeatIntervalSeconds, interval.isFinite, interval > 0 {
      return interval
    }
    guard backend.capabilities.supportsDaemonRecurrence, loopType == .timeBased,
      let prompt = triggerPrompt, let recurrence = SessionPrompt.recurrence(of: prompt)
    else { return nil }
    return SessionPrompt.intervalSeconds(recurrence.interval)
  }

  public var heartbeatTask: String? {
    triggerPrompt.map { SessionPrompt.firstPass(of: $0) ?? $0 }
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
  /// because nothing else would restart them — as opposed to a turn-based node or a
  /// sketch, which a human opening is what starts. See `LoopType.runsUnattended`.
  public var runsUnattended: Bool {
    loopType.runsUnattended
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
  /// Whether the last presence reading says a session actually exists to attach to.
  /// `nil` and `.unknown` count as no: opening is what could *start* a session, and a
  /// gate deciding whether that's safe must not treat "don't know" as "yes".
  public var presenceShowsLiveSession: Bool {
    if presence?.exitCode != nil { return false }
    switch presence?.presence {
    case .busy, .idle, .awaitingInput: return true
    case .absent, .unknown, nil: return false
    }
  }

  /// Whether a human's tap may open this loop's workspace right now — the one rule
  /// behind every gesture that opens a loop (a card tap, a sidebar row, ⇧⌘]'s walk,
  /// history's Back), so click and keyboard cannot come to disagree.
  ///
  /// Three ways to qualify, in the order they decide:
  /// - Not `.blocked`: nothing is holding it, opening is plainly fine.
  /// - A live session: creation starts an unattended child's session before a
  ///   follow-up hand-off edge marks it blocked, and a terminal that exists must be
  ///   reachable.
  /// - Attended: a turn-based or sketch loop only ever runs because a human opened
  ///   it, so the human's tap *is* the authorization the hand-off was guarding.
  ///   Refusing it left a hand-off-wired child unreachable by every gesture the app
  ///   has, silently, until its parent resolved (#194's orchestration shape).
  ///
  /// What stays gated: a blocked *unattended* loop with no session, where opening
  /// would start sequenced work the graph says must wait — and the daemon would start
  /// it itself the moment the hand-off fires anyway.
  public var opensOnHumanTap: Bool {
    state != .blocked || presenceShowsLiveSession || !runsUnattended
  }

  /// A backend that reports nothing leaves `presence` nil and this returns `state`
  /// untouched, which is exactly the behaviour every surface had before presence existed.
  public var displayState: LoopState {
    guard state == .running, let presence = presence?.presence else { return state }
    if let exitCode = self.presence?.exitCode {
      return exitCode == 0 ? .idle : .failed
    }
    switch presence {
    case .busy: return .running
    case .idle: return hasActiveDependents ? .waiting : .idle
    case .absent: return displayStateForAbsentSession
    // The combination `Presence` was written for: running in the graph, waiting on a
    // human in its session.
    case .awaitingInput: return .awaitingInput
    // A probe that failed in transport observed nothing — the graph's own belief is
    // the only honest thing left to show, exactly as if no reading existed.
    case .unknown: return state
    }
  }

  /// How long after a node's creation an `absent` presence reading is still allowed to
  /// look like ordinary quiet. A freshly created loop's session takes a moment to exist
  /// (the ensure is fired, not awaited, and a remote one crosses ssh first), so the
  /// first poll of a young node can read `absent` while the launch is still in flight;
  /// past this grace an absent session on an unattended loop is not quiet — it is a
  /// session that exited with nobody watching, issue #215's silent death.
  public static let absentSessionGraceSeconds: TimeInterval = 60

  /// A `.running` unattended loop whose session is *gone* is a dead loop, and IDLE is
  /// the one word it must not show: nothing is waiting for work, there is no work and
  /// no loop to do it — that is the `failed` the graph would record if anyone had seen
  /// the exit. Attended (turn-based) loops stay IDLE: a human owns those sessions, and
  /// the pane they open is the place the exit shows. A loop others are still waiting
  /// on shows `waiting` either way — that word is about the dependents, and their edge
  /// is the graph's business, not the presence poll's.
  private var displayStateForAbsentSession: LoopState {
    guard runsUnattended, !hasActiveDependents else {
      return hasActiveDependents ? .waiting : .idle
    }
    let grace = Date().addingTimeInterval(-Self.absentSessionGraceSeconds)
    return createdAt < grace ? .failed : .idle
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
    case lastMailroomRead, mailroomWatch
    case state, createdAt, activity, presence, firstInstruction, pausesBeforeWritesOnly
    case summary, board, heartbeatIntervalSeconds, stallReason
    case createdFromTemplateID, templateFollow, sessionRestarts
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
    heartbeatIntervalSeconds =
      try container.decodeIfPresent(Double.self, forKey: .heartbeatIntervalSeconds)
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
    sessionRestarts = try container.decodeIfPresent(Int.self, forKey: .sessionRestarts) ?? 0
    activity = try container.decodeIfPresent(String.self, forKey: .activity)
    // Unlike `presence` and `activity`, this survives a reload: pass summaries are the
    // account of a run, and a resolved loop's is the thing worth reading after the fact.
    // It is bounded by construction, so a graph file cannot grow on it.
    summary = try container.decodeIfPresent(LoopSummary.self, forKey: .summary)
    // Survives a reload for the reason above, and one more: it cost a model call, and a
    // picture that has to be paid for again on every relaunch is a picture nobody keeps.
    board = try container.decodeIfPresent(SummaryBoard.self, forKey: .board)
    presence = try container.decodeIfPresent(PresenceReading.self, forKey: .presence)
    metricHistory =
      try container.decodeIfPresent([MetricSample].self, forKey: .metricHistory) ?? []
    createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
    createdFromTemplateID =
      try container.decodeIfPresent(UUID.self, forKey: .createdFromTemplateID)
    // Absent on every graph saved before templates existed — those loops were all
    // snapshots, which is what nil says.
    templateFollow = try container.decodeIfPresent(
      TemplateFollow.self, forKey: .templateFollow)
    // Absent from graphs saved before the Mailroom existed — every loop simply has
    // not read anything yet, which is what `nil` says.
    lastMailroomRead =
      try container.decodeIfPresent(Int.self, forKey: .lastMailroomRead)
      ?? decoder.legacyMailroomValue(Int.self, "lastArtifactoryRead")
    mailroomWatch =
      try container.decodeIfPresent(MailroomWatch.self, forKey: .mailroomWatch)
      ?? decoder.legacyMailroomValue(MailroomWatch.self, "artifactoryWatch")
    stallReason = try container.decodeIfPresent(String.self, forKey: .stallReason)
    state = try container.decodeIfPresent(LoopState.self, forKey: .state) ?? .idle
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }
}
