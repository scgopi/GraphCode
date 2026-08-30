import Foundation

/// Everything the node-configuration panel collects
/// (docs/06-ux-terminals.md#node-configuration-panel), in one value.
///
/// This replaced three separate `createTurnBasedNode`/`createTimeBasedNode`/
/// `createGoalBasedNode` wire commands. The three differed only in which type-specific
/// field they carried, while every one of them would have needed the same additions —
/// worktree binding, backend, model tier — as later phases landed. One draft with
/// per-type fields keeps that growth in a struct instead of multiplying it across the
/// protocol's shape.
///
/// The type-specific fields stay loose rather than becoming an enum with associated
/// values because `LoopNode` itself stores them that way; making the draft stricter than
/// the thing it builds would just move the same validation somewhere less useful.
/// `isValid` is where the real rules live.
public struct NodeDraft: Codable, Equatable, Sendable {
  /// The id the created node will carry — chosen by the *client*, not the daemon.
  ///
  /// This is what makes an async follow-up to creation addressable: the form fires a
  /// title suggestion off to a backend when the human leaves the title blank, and by the
  /// time the answer arrives the only handle it has is this id. Without it, the client
  /// would have to diff two `graphChanged` broadcasts to guess which node it just made.
  public var id: UUID
  /// Optional — a blank title creates the node as "New Loop" (see `makeNode`), on the
  /// theory that naming every loop up front was the most tedious field on the form and
  /// the one a backend can fill in afterward.
  public var title: String
  public var loopType: LoopType
  /// `.turnBased`: what a human verifies each turn.
  public var checkDescription: String?
  /// `.timeBased`: the opening prompt, cadence included as a `/loop` directive. Also
  /// where a `.composite` draft carries the schedule it is *intended* to run on — the
  /// composite doesn't run at creation, so this is a statement of intent until it's
  /// piloted and armed.
  public var triggerPrompt: String?
  /// `.timeBased`, experimental: ask the daemon to drive this loop on its own timer —
  /// see `LoopNode.heartbeatIntervalSeconds`. Refused at creation unless
  /// `GraphcodeSettings.daemonHeartbeatEnabled` is on.
  public var heartbeatIntervalSeconds: Double?
  /// `.turnBased`: what the session should actually do. See `LoopNode.firstInstruction`.
  /// `.sketch`: the optional starting note — blank means the session opens quiet.
  public var firstInstruction: String?
  /// `.turnBased`: pause only before writes rather than after every turn.
  public var pausesBeforeWritesOnly: Bool
  /// `.goalBased`: the stop condition.
  public var goal: GoalSpec?
  /// `nil` means "nobody chose one": the daemon resolves it at creation — the creating
  /// loop's own backend when this draft came from a session fanning out (`createdBy`),
  /// Claude Code otherwise. Optional precisely so that inheritance is expressible: a
  /// non-optional field made every CLI-created child silently Claude Code, because the
  /// wire couldn't tell "explicitly Claude" from "defaulted".
  public var backend: CLISessionBackendKind?
  /// `nil` leaves the tier to the orchestrator's routing policy for this loop type.
  public var modelTier: ModelTier?
  public var worktree: WorktreeRef?
  /// A `.composite` draft's sub-graph, when one is being carried across — a cross-graph
  /// `.spawn` of a composite has to bring the routine with it, or the receiving project
  /// gets an empty shell. `nil` means "start empty", which is what the creation form
  /// sends.
  public var subGraph: LoopGraph?
  /// The loop that asked for this one, when a running session created it through the CLI.
  ///
  /// Recorded so the graph shows what actually happened: a loop that fans work out into
  /// five loops is the origin of those five, and drawing them as five unrelated entry
  /// points hanging off the folder would say the opposite. `GraphStore` turns this into a
  /// real, already-fired `.handoff` edge — see `createNode`.
  ///
  /// `nil` for anything a human created, which is the truth: the form is not a loop.
  public var createdBy: UUID?

  public init(
    id: UUID = UUID(),
    title: String,
    loopType: LoopType,
    checkDescription: String? = nil,
    triggerPrompt: String? = nil,
    heartbeatIntervalSeconds: Double? = nil,
    firstInstruction: String? = nil,
    pausesBeforeWritesOnly: Bool = false,
    goal: GoalSpec? = nil,
    backend: CLISessionBackendKind? = nil,
    modelTier: ModelTier? = nil,
    worktree: WorktreeRef? = nil,
    subGraph: LoopGraph? = nil,
    createdBy: UUID? = nil
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
    self.worktree = worktree
    self.subGraph = subGraph
    self.createdBy = createdBy
  }

  /// docs/08-quality-and-token-budgets.md wants the cheap-to-ignore version of each
  /// principle to be structurally awkward: no check means no turn-based node, no stop
  /// condition means no goal-based node. Enforced here, on the daemon side, rather than
  /// only in the form — the wire protocol is reachable from the CLI too, and a rule that
  /// only one client applies isn't a rule.
  public var isValid: Bool {
    // No title requirement: `makeNode` falls back to "New Loop", and the app follows up
    // with a backend-suggested name (see `TitleSuggestionClient`). Requiring one taught
    // people to type a throwaway word to get past the form — the prompt is the field
    // that means something, so it's the one each type below actually demands.
    //
    // docs/04-cli-backends.md: refuse the pairing rather than silently degrading a loop
    // to something its backend can actually manage.
    guard effectiveBackend.canHost(loopType) else { return false }
    switch loopType {
    case .sketch:
      // Valid while completely empty — the whole point of the type. `⏎` on an untouched
      // dialog is a complete action; the starting note is the one field, and optional.
      return true
    case .turnBased:
      // The *criterion* stays optional, for the reason it always was: a turn-based
      // loop's hand-off is a human watching it, and that human exists whether or not
      // they wrote down in advance what they would be looking for. Refusing the node
      // over that taught people to type "check" in the box to get past the form.
      //
      // The **first instruction** is not optional, and this is the one type where that
      // used to be missing entirely: with no task field the session opened knowing it
      // should pause and what it would be judged on, but never what to start doing. A
      // loop with nothing to do is not a loop.
      return !(firstInstruction ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    case .goalBased:
      return !(goal?.summary ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    case .timeBased:
      let prompt = (triggerPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !prompt.isEmpty else { return false }
      if let heartbeatIntervalSeconds,
        !heartbeatIntervalSeconds.isFinite || heartbeatIntervalSeconds <= 0
      {
        return false
      }
      let capabilities = effectiveBackend.capabilities
      guard capabilities.supportsDaemonRecurrence && !capabilities.supportsInSessionRecurrence
      else { return true }
      if heartbeatIntervalSeconds != nil { return true }
      guard let recurrence = SessionPrompt.recurrence(of: prompt) else { return false }
      return SessionPrompt.intervalSeconds(recurrence.interval) != nil
    case .composite:
      // Its *contents* are still not required — a composite is built by editing its
      // sub-graph after creation, and demanding a populated one at creation time would
      // mean a modal that can't be filled in until the thing it creates exists. The real
      // gate is arming, which `PilotState` refuses until the composite has been run.
      //
      // A name is required, though, and only here: every other type gets one from its
      // own backend after it starts working (`TitleSuggestionClient`), and a composite
      // never starts. "New Loop" would be its name for good.
      return !title.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }

  /// What an untitled draft's node is called until something better arrives — the app
  /// asks the loop's own backend for a real name and renames the node when it answers.
  public static let untitledFallback = "New Loop"

  /// The backend this draft builds with when nobody resolved one. `GraphStore` resolves
  /// inheritance *before* this is consulted — a child created by a running loop takes
  /// that loop's backend — so this fallback only decides for drafts with no creator.
  public var effectiveBackend: CLISessionBackendKind {
    backend ?? .claudeCode
  }

  /// The title the node is actually created with — never blank, because the graph, the
  /// sidebar, and the canvas would all render a nameless card.
  public var resolvedTitle: String {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? Self.untitledFallback : trimmed
  }

  /// A goal-based loop is `.running` from creation: its session starts working
  /// immediately, with no human turn or trigger in between. Everything else waits.
  public func makeNode() -> LoopNode {
    LoopNode(
      // The draft's own id, not a fresh one — the client that built the draft may
      // already be holding this id to address a follow-up at (see `id`).
      id: id,
      title: resolvedTitle,
      loopType: loopType,
      checkDescription: checkDescription,
      triggerPrompt: triggerPrompt,
      heartbeatIntervalSeconds: heartbeatIntervalSeconds,
      firstInstruction: firstInstruction,
      pausesBeforeWritesOnly: pausesBeforeWritesOnly,
      goal: goal,
      backend: effectiveBackend,
      modelTier: modelTier,
      worktreeBinding: worktree,
      // A composite always gets a sub-graph, empty to begin with — its own graph is what
      // it *is*, and a nil one would just be an unrepresentable state every call site
      // would have to guard against.
      subGraph: loopType == .composite
        ? (subGraph?.reIdentified()
          ?? LoopGraph(
            project: ProjectRef(path: "\(resolvedTitle)-subgraph", name: resolvedTitle)))
        : nil,
      createdBy: createdBy,
      state: loopType == .goalBased ? .running : .idle)
  }
}

extension NodeDraft {
  private enum CodingKeys: String, CodingKey {
    case id, title, loopType, checkDescription, triggerPrompt, goal, backend, modelTier
    case worktree, subGraph, createdBy, firstInstruction, pausesBeforeWritesOnly
    case heartbeatIntervalSeconds
  }

  /// `id` is `decodeIfPresent` because drafts also arrive over the wire from a CLI that
  /// may predate it — a loop's already-installed `graphcode` binary keeps creating nodes
  /// across the upgrade, its drafts simply getting daemon-assigned ids the way they
  /// always did.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    title = try container.decode(String.self, forKey: .title)
    loopType = try container.decode(LoopType.self, forKey: .loopType)
    checkDescription = try container.decodeIfPresent(String.self, forKey: .checkDescription)
    triggerPrompt = try container.decodeIfPresent(String.self, forKey: .triggerPrompt)
    heartbeatIntervalSeconds =
      try container.decodeIfPresent(Double.self, forKey: .heartbeatIntervalSeconds)
    firstInstruction = try container.decodeIfPresent(String.self, forKey: .firstInstruction)
    // Absent from drafts written by a CLI that predates the field. Those loops paused
    // after every turn, which is what `false` means.
    pausesBeforeWritesOnly =
      try container.decodeIfPresent(Bool.self, forKey: .pausesBeforeWritesOnly) ?? false
    goal = try container.decodeIfPresent(GoalSpec.self, forKey: .goal)
    backend = try container.decodeIfPresent(CLISessionBackendKind.self, forKey: .backend)
    modelTier = try container.decodeIfPresent(ModelTier.self, forKey: .modelTier)
    worktree = try container.decodeIfPresent(WorktreeRef.self, forKey: .worktree)
    subGraph = try container.decodeIfPresent(LoopGraph.self, forKey: .subGraph)
    createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
  }
}
