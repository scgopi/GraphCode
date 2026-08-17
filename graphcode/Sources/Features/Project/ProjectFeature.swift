import ComposableArchitecture
import Foundation
import GraphcodeKit

/// One open project's graph canvas — one of possibly several the sidebar shows at once
/// (multi-project sidebar follow-up to Phase 4, docs/07-roadmap.md#phase-4--projects).
///
/// Selection (which node's terminal is showing, if any) used to live here, back when
/// only one project could be open at a time — now that the sidebar can show several
/// projects sharing one detail pane, "what's selected" is inherently cross-project, so
/// it moved up to `AppFeature.State.detail`/`.selectedProjectPath`. `.nodeTapped`
/// is still declared here (both the sidebar's node rows and the canvas's node cards are
/// rendered off a project-scoped store), but this feature's own reducer does nothing
/// with it — it's purely a signal `AppFeature`'s parent `Reduce` intercepts.
///
/// Still mirrors whatever `graphcoded` broadcasts for this project rather than owning
/// graph state directly — node/edge-creation actions send a `GraphCommand` (wrapped in
/// `.graphCommand(projectPath:, command:)`) and wait for the resulting `.graphChanged`
/// broadcast; automatic `.handoff` firing happens in the daemon (see
/// `graphcoded/Sources/GraphStore.swift`). `nodePositions` stays local — canvas layout
/// is a UI concern the daemon has no reason to know about. `AppFeature` owns the one
/// daemon subscription for the app's whole lifetime and forwards this project's
/// `DaemonEvent`s in via `.daemonEvent`.
@Reducer
struct ProjectFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    var graph: LoopGraph
    var nodePositions: [UUID: CGPoint] = [:]
    /// The composite the canvas is currently *inside*, if any — see `canvasGraph`.
    ///
    /// A composite is "a graph inside a graph" (docs/01-loop-taxonomy.md), and until this
    /// existed there was no way to get in: the new-loop dialog promised "Add loops inside"
    /// and offered a **Create & open** button, and nothing anywhere could open one or put
    /// a loop in one, so every composite ever created stayed empty for good.
    var openCompositeID: UUID?
    var showingNewNodeForm = false
    /// The id the node being drafted will be created under, fixed when the form opens.
    /// Stored rather than letting `NodeDraft.init` default one, because `draft` is
    /// *computed* — a fresh id per access would mean the id sent in `.createNode` and
    /// the id a later `.renameNode` targets were never the same node.
    var draftID = UUID()
    var draftLoopType: LoopType = .goalBased
    var draftTitle = ""
    var draftCheck = ""
    var draftPrompt = ""
    var draftGoal = ""
    var draftPredicate = ""
    /// The goal's optional score — `GoalSpec.metricCommand`, sampled once per cycle
    /// pass. Distinct from the predicate on purpose: one answers "done?", the other
    /// "how is it going?".
    var draftMetric = ""
    var draftMetricDirection: MetricDirection = .maximize
    /// Collapsed by default — a metric is off the path for the common goal loop, and a
    /// command field sitting open invites people to fill it in because it is there.
    var isMetricExpanded = false
    /// What pressing **Test** on the done check found, and whether one is in flight.
    var doneCheckOutcome: DoneCheckOutcome?
    var isTestingDoneCheck = false
    /// `.turnBased`: what the session is asked to do, and where it pauses.
    var draftFirstInstruction = ""
    var draftPausesBeforeWritesOnly = false
    /// `.timeBased`: how often, and what to do each time. GraphCode composes the `/loop`
    /// directive from the two — see `ProjectFeature.State.composedTriggerPrompt`.
    var draftInterval: IntervalChoice = .hourly
    var draftCustomInterval = ""
    var draftTimedTask = ""
    var draftStopAfter = ""
    /// `.composite`: the schedule this composite is *meant* for. Nothing runs at
    /// creation, so it is a statement of intent until the thing is piloted and armed.
    var draftSchedule: CompositeSchedule = .daily
    var draftScheduleTime = "09:00"
    var draftBackend: CLISessionBackendKind = .claudeCode
    var draftModelTier: ModelTier?
    var draftWorktree: WorktreeSelection = .none
    var draftBranch = ""
    /// Set when the form was opened from a node card's + handle: the node the new loop
    /// hangs off. Creation then also draws a hand-off edge from it — see
    /// `createNodeConfirmed`.
    var draftParentNodeID: UUID?
    /// Worktrees already present in this project's repository, loaded when the form
    /// opens. Empty for a folder that isn't a git repo — the picker then only offers
    /// "None" and "New branch", and creating one simply fails and reports why.
    var availableWorktrees: [WorktreeRef] = []
    var connectionError: String?

    /// Set when an edge has been dragged but not yet confirmed — dropping onto a node
    /// opens the editor (docs/06-ux-terminals.md#creating-edges) instead of committing
    /// a default `.handoff` straight away.
    var pendingEdge: PendingEdge?

    /// Set while the "delete this loop?" confirmation is up. Deleting a node also kills
    /// its detached session, so it gets a confirmation where deleting an edge — which
    /// only removes a relationship — doesn't.
    var nodePendingDeletion: UUID?

    /// Set while the rename prompt is up, with `draftRenameTitle` holding what has been
    /// typed so far. Two fields rather than one optional draft struct, to match how
    /// `nodePendingDeletion` and the creation form's `draft*` fields already work here.
    var nodePendingRename: UUID?
    var draftRenameTitle = ""

    /// Loops a human said really are a beginning, despite having no edges — the answer
    /// to a card's "Mark as entry". View state, not graph state: the graph's own answer
    /// to "does this start something" is its edges, and a stored flag would be a second
    /// answer free to disagree with them. See `CardEntryRole`.
    var declaredEntryIDs: Set<UUID> = []

    /// The sidebar's display order for this project's loops, node ids first-to-last.
    /// Local UI state like `nodePositions`: the daemon's graph carries no ordering a
    /// human chose, so a `graphChanged` broadcast must not clobber a rearrangement —
    /// new nodes append, deleted nodes drop out, and the rest keep their places.
    var sidebarNodeOrder: [UUID] = []

    /// A loop just created from this app's own form, waiting for the daemon's
    /// `graphChanged` broadcast to deliver it — at which point its workspace opens via
    /// `.nodeTapped`. The node can't be opened at creation time because it doesn't
    /// exist locally until the broadcast lands. Only ever set on the form path: a loop
    /// created from the CLI arrives as a bare broadcast with nothing pending, so it
    /// never steals focus.
    var pendingCreatedNodeID: UUID?

    /// Loops whose worktree can be reclaimed right now — set at the resolve moment when
    /// the folder's policy is "Ask me" (see `AppWorktreesReducer`), read by the card's
    /// inline Reclaim/Keep. Keyed by node id; an offer outlives nothing: it drops the
    /// moment its loop is deleted or answered.
    var worktreeReclaimOffers: [UUID: WorktreeAssessment] = [:]

    /// This folder's worktree stats, mirrored in by `AppWorktreesReducer` when it loads
    /// them — so the canvas, which only holds a project-scoped store, can put the count
    /// on its own `Worktrees…` menu item.
    var worktreeStats: WorktreeFolderStats?

    var id: String { graph.project.path }

    init(graph: LoopGraph) {
      self.graph = graph
      var positions: [UUID: CGPoint] = [:]
      var taken = Set<CGPoint>()
      for node in graph.nodes {
        let position = ProjectFeature.nextFreePosition(avoiding: taken)
        positions[node.id] = position
        taken.insert(position)
      }
      self.nodePositions = positions
      self.sidebarNodeOrder = graph.nodes.map(\.id)
    }
  }

  // `TransformMode` and `PendingEdge` — the edge editor's draft types — live in
  // `ProjectFeatureState.swift` with the form's other small types.

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case daemonEvent(DaemonEvent)
    case addNodeButtonTapped(parentBackend: CLISessionBackendKind?)
    /// The + handle on a node card: opens the same form, and the created loop gets a
    /// hand-off edge from this node.
    case addChildNodeTapped(UUID)
    case createNodeConfirmed
    case cancelNewNodeForm
    case nodeTapped(UUID)
    /// Drill into a composite — the canvas starts drawing its sub-graph instead.
    case compositeOpened(UUID)
    /// The breadcrumb's way back out to the project's own graph.
    case compositeClosed
    /// This canvas's attention rail. Scoped to this project on purpose: the rail sits on
    /// *this folder's* canvas, so the loop it opens should be one you can see. ⌘⇧R from
    /// the window is the cross-project door — see `AppFeature.reviewAttentionTapped`.
    case reviewAttentionTapped
    /// "Mark as entry" on a loop wired to nothing — see `CardEntryRole`.
    case markAsEntryTapped(UUID)
    /// The **Test** button beside a goal's done check: runs the command exactly the way
    /// `graphcoded` will and reports what happened.
    case doneCheckTestTapped
    case doneCheckTested(passed: Bool, duration: TimeInterval)
    case edgeDrawn(from: UUID, to: UUID)
    case createEdgeConfirmed
    case cancelEdgeForm
    case deleteNodeRequested(UUID)
    case deleteNodeConfirmed
    case deleteNodeCancelled
    case renameNodeRequested(UUID)
    /// The prompt's text field, one keystroke at a time. Not a `binding` because the
    /// field is hosted by `AppView` — see `AppFeature.State.pendingLoopRename` — which
    /// holds the app store rather than any one project's, so it has no `@Bindable`
    /// project store to bind through.
    case renameTitleChanged(String)
    case renameNodeConfirmed
    case renameNodeCancelled
    case deleteEdgeTapped(UUID)
    /// The sidebar dropped a drag-to-reorder: the moved ids in their new order, which
    /// take the front of `sidebarNodeOrder`; ids not in the list keep their relative
    /// order behind them.
    case sidebarNodesReordered([UUID])
    case stopNodeTapped(UUID)
    case pilotCompositeTapped(UUID)
    case armCompositeTapped(UUID)
    case refreshUsageTapped
    case worktreesLoaded([WorktreeRef])
    case worktreeCreationFailed(String)
    /// The resolve moment, when this folder's policy is "Ask me" — the card offers
    /// Reclaim/Keep while the human still remembers what the worktree was.
    case worktreeReclaimOffered(nodeID: UUID, assessment: WorktreeAssessment)
    /// Clearing the offer is this scope's job; the removal itself needs `GitClient`
    /// and happens in `AppWorktreesReducer`, which intercepts the same action.
    case reclaimWorktreeTapped(UUID)
    case keepWorktreeTapped(UUID)
    /// The canvas background's folder menu. Pure signals like `.nodeTapped`: the sheets
    /// they open are hosted by `AppView`, so `AppWorktreesReducer` intercepts both.
    case worktreeSweepTapped
    case projectSettingsTapped
  }

  @Dependency(\.gitClient) var gitClient
  /// Names an untitled loop after creation — see `createNodeConfirmed`.
  @Dependency(\.titleSuggestionClient) var titleSuggestionClient

  @Dependency(\.orchestratorClient) var orchestratorClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .daemonEvent(let event):
        switch event {
        case .graphChanged(let newGraph):
          state.connectionError = nil
          // Slots are taken by what's *there*, not by how many there are. Indexing by
          // count meant deleting a loop freed its position but shifted the counter back,
          // so the next node landed exactly on top of an existing card — four loops
          // rendering as one, with the rest hidden underneath.
          var taken = Set(state.nodePositions.values)
          // Composites' contents get slots too, or a drilled-in canvas draws every card
          // at the same unplaced point. Positions are keyed by node id and ids are unique
          // across the whole tree, so one flat table serves every level.
          for node in newGraph.nodes.flatMap({ [$0] + ($0.subGraph?.nodes ?? []) })
          where state.nodePositions[node.id] == nil {
            let position = Self.nextFreePosition(avoiding: taken)
            taken.insert(position)
            state.nodePositions[node.id] = position
          }
          state.graph = newGraph
          // An offer only makes sense while its loop exists, stays resolved, and still
          // points at the worktree — a restarted or deleted loop takes it with it.
          state.worktreeReclaimOffers = state.worktreeReclaimOffers.filter { id, _ in
            newGraph.nodes[id: id].map { $0.isResolved && $0.worktreeBinding != nil } == true
          }
          // Keep the human's sidebar arrangement across broadcasts: drop ids the graph
          // no longer has, append ones it gained, and touch nothing else.
          let currentIDs = Set(newGraph.nodes.map(\.id))
          state.sidebarNodeOrder.removeAll { !currentIDs.contains($0) }
          for node in newGraph.nodes where !state.sidebarNodeOrder.contains(node.id) {
            state.sidebarNodeOrder.append(node.id)
          }
          // The broadcast that delivers a form-created loop is what makes it openable —
          // switch to it now, the way tapping it would. Matched by id so an unrelated
          // broadcast (another loop finishing, a CLI edit) leaves the pending id waiting.
          if let pending = state.pendingCreatedNodeID, newGraph.nodes[id: pending] != nil {
            state.pendingCreatedNodeID = nil
            return .send(.nodeTapped(pending))
          }
        case .errorOccurred(let message):
          state.connectionError = message
        case .recentProjectsListed:
          break  // Not this feature's concern — AppFeature routes this to `welcome`.
        }
        return .none

      case .addNodeButtonTapped(let parentBackend):
        return openNodeForm(&state, backend: parentBackend, parentNodeID: nil)

      case .addChildNodeTapped(let parentID):
        // The child inherits its parent's backend, same rule as creating from within an
        // open loop's workspace.
        return openNodeForm(
          &state, backend: state.graph.nodes[id: parentID]?.backend, parentNodeID: parentID)

      case .cancelNewNodeForm:
        state.showingNewNodeForm = false
        return .none

      case .createNodeConfirmed:
        let draft = state.draft
        // `isValid` carries the same rules the daemon enforces, so an incomplete form
        // simply doesn't submit — the Create button is disabled on it too, and this is
        // the backstop for the keyboard shortcut path.
        guard draft.isValid else { return .none }
        let projectPath = state.graph.project.path
        // A form opened from a node card's + handle also wires the new loop up: a
        // default hand-off edge from the parent, created right after the node so the
        // graph never broadcasts a child floating unconnected.
        let parentNodeID = state.draftParentNodeID
        state.draftParentNodeID = nil
        state.showingNewNodeForm = false
        // Inside a composite, the same commands are addressed at its sub-graph. This is
        // the app half of "add loops inside" — the step the dialog's own strip promises.
        let insideComposite = state.openCompositeID
        // **Create & open**, honoured: a composite made from the project canvas opens
        // straight away, which is what its button has always said it would do. Only from
        // the top level — a composite created inside another would otherwise take the
        // canvas somewhere the human didn't ask to go.
        if draft.loopType == .composite, insideComposite == nil {
          state.openCompositeID = draft.id
        }
        // A loop created from the form switches to itself once its broadcast lands —
        // see `pendingCreatedNodeID`. Not composites: opening their sub-graph canvas
        // (above) already is the switch. Not inside a composite either: the drilled-in
        // canvas the human is looking at is where the new card appears, and workspace
        // opening (`AppFeature`'s `.nodeTapped`) only reaches top-level nodes anyway.
        if draft.loopType != .composite, insideComposite == nil {
          state.pendingCreatedNodeID = draft.id
        }

        // Creating the worktree is the app's job, not the daemon's: `GitClient` lives
        // here, and a failure needs somewhere to be shown. If it fails, the node is
        // still created — unbound rather than not at all — since losing the loop over a
        // branch that already exists would be the more annoying outcome.
        let request = state.newWorktreeRequest
        return .run { send in
          var resolved = draft
          if let request {
            do {
              resolved.worktree = try await gitClient.createWorktree(
                request.repositoryPath, request.worktreePath, request.branch)
            } catch {
              await send(.worktreeCreationFailed(String(describing: error)))
            }
          }
          func addressed(_ command: GraphCommand) -> GraphCommand {
            insideComposite.map { .subGraphCommand(nodeID: $0, command: command) } ?? command
          }
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: addressed(.createNode(resolved))))
          if let parentNodeID {
            try? await orchestratorClient.send(
              .graphCommand(
                projectPath: projectPath,
                command: addressed(
                  .createEdge(from: parentNodeID, to: draft.id, spec: EdgeSpec()))))
          }

          // A blank title creates the node as "New Loop" and asks the loop's own
          // backend for a real one — after creation, so a slow (or absent) CLI never
          // holds the node itself hostage. The rename can target the node because the
          // draft's id *is* the node's id (see `NodeDraft.id`); no answer just means
          // the fallback name stays.
          guard draft.title.trimmingCharacters(in: .whitespaces).isEmpty,
            let basis = [draft.checkDescription, draft.triggerPrompt, draft.goal?.summary]
              .compactMap({ $0 })
              .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
            let title = await titleSuggestionClient.suggest(draft.effectiveBackend, basis)
          else { return }
          try? await orchestratorClient.send(
            .graphCommand(
              projectPath: projectPath, command: addressed(.renameNode(draft.id, title: title))))
        }

      case .worktreeCreationFailed(let message):
        state.connectionError = "Couldn't create worktree: \(message)"
        return .none

      case .worktreesLoaded(let worktrees):
        state.availableWorktrees = worktrees
        return .none

      case .worktreeReclaimOffered(let nodeID, let assessment):
        // Only for a loop that still exists and is still resolved — the assessment ran
        // against a snapshot, and the graph may have moved since.
        guard state.graph.nodes[id: nodeID]?.isResolved == true else { return .none }
        state.worktreeReclaimOffers[nodeID] = assessment
        return .none

      case .reclaimWorktreeTapped(let nodeID), .keepWorktreeTapped(let nodeID):
        state.worktreeReclaimOffers[nodeID] = nil
        return .none

      case .worktreeSweepTapped, .projectSettingsTapped:
        // Handled by `AppWorktreesReducer` — the sheets are hosted app-level.
        return .none

      case .nodeTapped:
        // Handled by `AppFeature`'s parent `Reduce`, which owns cross-project
        // selection — nothing to do here.
        return .none

      case .compositeOpened(let nodeID):
        guard state.graph.nodes[id: nodeID]?.loopType == .composite else { return .none }
        state.openCompositeID = nodeID
        return .none

      case .compositeClosed:
        state.openCompositeID = nil
        return .none

      case .doneCheckTestTapped:
        let command = state.draftPredicate.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !state.isTestingDoneCheck else { return .none }
        state.isTestingDoneCheck = true
        state.doneCheckOutcome = nil
        let directory = state.graph.project.path
        return .run { send in
          let result = await ShellPredicateEvaluator.probe(
            ShellPredicate(command: command, workingDirectory: directory))
          await send(
            .doneCheckTested(
              passed: result?.passed ?? false, duration: result?.duration ?? 0))
        }

      case .doneCheckTested(let passed, let duration):
        state.isTestingDoneCheck = false
        state.doneCheckOutcome = DoneCheckOutcome(passed: passed, duration: duration)
        return .none

      case .markAsEntryTapped(let nodeID):
        state.declaredEntryIDs.insert(nodeID)
        return .none

      case .reviewAttentionTapped:
        // Oldest first: the loop that has been waiting longest is the one to answer,
        // and it is the same rule the window's ⌘⇧R follows.
        guard let oldest = state.attentionItems.oldestFirst.first else { return .none }
        return .send(.nodeTapped(oldest.nodeID))

      case .edgeDrawn(let from, let to):
        guard from != to else { return .none }
        state.pendingEdge = PendingEdge(from: from, to: to)
        return .none

      case .cancelEdgeForm:
        state.pendingEdge = nil
        return .none

      case .deleteNodeRequested(let nodeID):
        state.nodePendingDeletion = nodeID
        return .none

      case .deleteNodeCancelled:
        state.nodePendingDeletion = nil
        return .none

      case .deleteNodeConfirmed:
        guard let nodeID = state.nodePendingDeletion else { return .none }
        state.nodePendingDeletion = nil
        // Local canvas layout is this feature's own, so it's cleaned up here rather
        // than waiting for the daemon's broadcast — otherwise a recreated node could
        // inherit the dead one's position.
        state.nodePositions[nodeID] = nil
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .deleteNode(nodeID)))
        }

      case .renameNodeRequested(let nodeID):
        guard let node = state.graph.nodes[id: nodeID] else { return .none }
        state.nodePendingRename = nodeID
        // Prefilled with the title it already has: renaming a loop is almost always
        // amending a name, not writing a new one from nothing.
        state.draftRenameTitle = node.title
        return .none

      case .renameTitleChanged(let title):
        state.draftRenameTitle = title
        return .none

      case .renameNodeCancelled:
        state.nodePendingRename = nil
        state.draftRenameTitle = ""
        return .none

      case .renameNodeConfirmed:
        guard let nodeID = state.nodePendingRename else { return .none }
        let title = state.draftRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = state.graph.nodes[id: nodeID]?.title
        state.nodePendingRename = nil
        state.draftRenameTitle = ""
        // Nothing typed, or nothing changed: close the prompt and say nothing. The
        // daemon refuses a blank title anyway (see `GraphStore.renameNode`); this is so
        // an empty field reads as "never mind" rather than as a command that quietly
        // did nothing.
        guard !title.isEmpty, title != current else { return .none }
        return send(state, .renameNode(nodeID, title: title))

      case .sidebarNodesReordered(let orderedIDs):
        let rest = state.sidebarNodeOrder.filter { !orderedIDs.contains($0) }
        state.sidebarNodeOrder = orderedIDs + rest
        return .none

      case .stopNodeTapped(let nodeID):
        return send(state, .stopNode(nodeID))

      case .pilotCompositeTapped(let nodeID):
        return send(state, .pilotComposite(nodeID))

      case .armCompositeTapped(let nodeID):
        return send(state, .armComposite(nodeID))

      case .refreshUsageTapped:
        return send(state, .refreshUsage)

      case .deleteEdgeTapped(let edgeID):
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .deleteEdge(edgeID)))
        }

      case .createEdgeConfirmed:
        guard let pending = state.pendingEdge else { return .none }
        state.pendingEdge = nil
        let projectPath = state.graph.project.path
        let spec = pending.resolvedSpec
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(
              projectPath: projectPath,
              command: .createEdge(from: pending.from, to: pending.to, spec: spec)))
        }
      }
    }
  }
}

extension ProjectFeature {
  /// Resets the draft fields and opens the node form — the shared half of
  /// `.addNodeButtonTapped` and `.addChildNodeTapped`.
  ///
  /// Goal-based by default, matching `LoopType`'s own ordering and the segmented
  /// control's first segment: a loop that starts itself and knows when it is finished
  /// is what most work wants, where the old turn-based default made a loop that sits
  /// idle until a human opens it — surprising as the *default* outcome of Create.
  private func openNodeForm(
    _ state: inout State, backend: CLISessionBackendKind?, parentNodeID: UUID?
  ) -> Effect<Action> {
    state.draftID = UUID()
    state.draftLoopType = .goalBased
    state.draftTitle = ""
    state.draftCheck = ""
    state.draftPrompt = ""
    state.draftGoal = ""
    state.draftPredicate = ""
    state.draftMetric = ""
    state.draftMetricDirection = .maximize
    state.isMetricExpanded = false
    state.doneCheckOutcome = nil
    state.isTestingDoneCheck = false
    state.draftFirstInstruction = ""
    state.draftPausesBeforeWritesOnly = false
    state.draftInterval = .hourly
    state.draftCustomInterval = ""
    state.draftTimedTask = ""
    state.draftStopAfter = ""
    state.draftSchedule = .daily
    state.draftScheduleTime = "09:00"
    // The parent's backend when there is one; the human's default otherwise
    // (Settings → Sessions), never a hardcoded one.
    state.draftBackend = backend ?? GraphcodeSettingsStore.load().defaultBackend
    let settings = GraphcodeSettingsStore.load()
    state.draftModelTier = settings.autoSelectsModel ? nil : settings.defaultModelTier
    state.draftWorktree = .none
    state.draftBranch = ""
    state.draftParentNodeID = parentNodeID
    state.showingNewNodeForm = true
    let repositoryPath = state.graph.project.path
    return .run { send in
      // A non-repo folder just yields nothing — a missing worktree list is not worth
      // an error banner when the picker degrades to "None" on its own.
      let worktrees = (try? await gitClient.listWorktrees(repositoryPath)) ?? []
      await send(.worktreesLoaded(worktrees))
    }
  }

  /// One-liner for the several actions that are just "route this straight to the
  /// daemon and wait for the broadcast".
  private func send(_ state: State, _ command: GraphCommand) -> Effect<Action> {
    let projectPath = state.graph.project.path
    return .run { _ in
      try? await orchestratorClient.send(
        .graphCommand(projectPath: projectPath, command: command))
    }
  }

  /// Simple grid layout for freshly synced nodes — real layout (force-directed,
  /// draggable repositioning) is future work; this just needs nodes to not overlap.
  /// The first grid slot nothing is sitting on.
  ///
  /// Deliberately not "the nth slot for the nth node": positions are removed when a loop
  /// is deleted, so a counter drifts out of step with the grid and starts handing out
  /// slots that are already occupied. Cards stacked pixel-perfectly on top of each other
  /// don't look like a layout bug — they look like the graph lost its nodes.
  ///
  /// Terminates because the grid is unbounded and `taken` is finite.
  static func nextFreePosition(avoiding taken: Set<CGPoint>) -> CGPoint {
    var index = 0
    while true {
      let candidate = gridPosition(index)
      if !taken.contains(candidate) { return candidate }
      index += 1
    }
  }

  /// Simple grid layout for freshly synced nodes — real layout (force-directed,
  /// draggable repositioning) is future work; this just needs nodes to not overlap.
  static func gridPosition(_ index: Int) -> CGPoint {
    let columns = 3
    let column = index % columns
    let row = index / columns
    return CGPoint(x: 160 + CGFloat(column) * 260, y: 140 + CGFloat(row) * 200)
  }
}
