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
  public var title: String
  public var loopType: LoopType
  /// `.turnBased`: what a human verifies each turn.
  public var checkDescription: String?
  /// `.timeBased`: the opening prompt, cadence included as a `/loop` directive.
  public var triggerPrompt: String?
  /// `.goalBased`: the stop condition.
  public var goal: GoalSpec?
  public var backend: CLISessionBackendKind
  /// `nil` leaves the tier to the orchestrator's routing policy for this loop type.
  public var modelTier: ModelTier?
  public var worktree: WorktreeRef?
  /// A `.proactive` draft's sub-graph, when one is being carried across — a cross-graph
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
    title: String,
    loopType: LoopType,
    checkDescription: String? = nil,
    triggerPrompt: String? = nil,
    goal: GoalSpec? = nil,
    backend: CLISessionBackendKind = .claudeCode,
    modelTier: ModelTier? = nil,
    worktree: WorktreeRef? = nil,
    subGraph: LoopGraph? = nil,
    createdBy: UUID? = nil
  ) {
    self.title = title
    self.loopType = loopType
    self.checkDescription = checkDescription
    self.triggerPrompt = triggerPrompt
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
    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    // docs/04-cli-backends.md: refuse the pairing rather than silently degrading a loop
    // to something its backend can actually manage.
    guard backend.canHost(loopType) else { return false }
    switch loopType {
    case .turnBased:
      // A criterion is optional. docs/08 asks for the cheap-to-ignore version of each
      // principle to be *structurally awkward*, and for goal-based it still is — a goal
      // with no summary describes nothing. But a turn-based loop's hand-off is a human
      // watching it, and that human exists whether or not they wrote down in advance what
      // they would be looking for. Refusing the node taught people to type "check" in the
      // box to get past the form, which is worse than an honest blank.
      return true
    case .goalBased:
      return !(goal?.summary ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    case .timeBased:
      return !(triggerPrompt ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    case .proactive:
      // A title is all that's required up front: a composite is *built* by editing its
      // sub-graph after creation, and demanding a populated one at creation time would
      // mean a modal that can't be filled in until the thing it creates exists. The real
      // gate is arming, which `PilotState` refuses until the composite has been run.
      return true
    }
  }

  /// A goal-based loop is `.running` from creation: its session starts working
  /// immediately, with no human turn or trigger in between. Everything else waits.
  public func makeNode() -> LoopNode {
    LoopNode(
      title: title,
      loopType: loopType,
      checkDescription: checkDescription,
      triggerPrompt: triggerPrompt,
      goal: goal,
      backend: backend,
      modelTier: modelTier,
      worktreeBinding: worktree,
      // A composite always gets a sub-graph, empty to begin with — its own graph is what
      // it *is*, and a nil one would just be an unrepresentable state every call site
      // would have to guard against.
      subGraph: loopType == .proactive
        ? (subGraph?.reIdentified()
          ?? LoopGraph(project: ProjectRef(path: "\(title)-subgraph", name: title)))
        : nil,
      state: loopType == .goalBased ? .running : .idle)
  }
}
