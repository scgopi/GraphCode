import AppKit
import ComposableArchitecture
import Foundation
import GraphcodeKit
import UniformTypeIdentifiers

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
    /// The goal's optional token budget (`GoalSpec.tokenBudget`), kept as typed so a
    /// half-edited number never round-trips into a different one. Parsed at draft
    /// assembly (`parsedBudget`); anything that isn't a positive integer travels as
    /// "no budget". Its row collapses for the same reason the metric's does.
    var draftBudget = ""
    var isBudgetExpanded = false
    /// What pressing **Test** on the done check found, and whether one is in flight.
    var doneCheckOutcome: DoneCheckOutcome?
    var isTestingDoneCheck = false
    /// `.turnBased`: what the session is asked to do, and where it pauses.
    var draftFirstInstruction = ""
    var draftPausesBeforeWritesOnly = false
    /// `.sketch`: the optional starting note. Its own field rather than sharing
    /// `draftFirstInstruction`, so flipping between types never carries text across.
    var draftSketchNote = ""
    /// `.timeBased`: how often, and what to do each time. GraphCode composes the `/loop`
    /// directive from the two — see `ProjectFeature.State.composedTriggerPrompt`.
    var draftInterval: IntervalChoice = .hourly
    /// `.timeBased`, experimental: the daemon holds the timer instead of the prompt
    /// carrying /loop. Offered by the form only while the Settings toggle is on;
    /// always defaults off, per loop — enabling the experiment converts nothing.
    var draftUsesHeartbeat = false
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
    /// Whether the open form makes a custody child (`.newChildLoopTapped`) rather
    /// than a handed-off one (`.addChildNodeTapped`).
    var draftParentIsCustodial = false
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

    /// Set while a sketch's promotion form is up: which sketch, which shape it is
    /// taking, and the one field that shape asks for. Flat fields to match how the
    /// rename prompt and the creation form's `draft*` fields already work here.
    var nodePendingPromotion: UUID?
    var promotionTarget: LoopType = .goalBased
    var promotionGoal = ""
    var promotionPausesBeforeWritesOnly = false
    var promotionInterval: IntervalChoice = .hourly
    var promotionCustomInterval = ""

    /// Loops a human said really are a beginning, despite having no edges — the answer
    /// to a card's "Mark as entry". View state, not graph state: the graph's own answer
    /// to "does this start something" is its edges, and a stored flag would be a second
    /// answer free to disagree with them. See `CardEntryRole`.
    var declaredEntryIDs: Set<UUID> = []
    /// Whether the open form was started from a lane's entry handle, so the loop it
    /// creates joins `declaredEntryIDs` instead of reading as a loose one.
    var draftDeclaresEntry = false

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
      self.nodePositions = LaneLayout.positions(forCanvas: graph)
      self.sidebarNodeOrder = graph.nodes.map(\.id)
    }
  }

  // `TransformMode` and `PendingEdge` — the edge editor's draft types — live in
  // `ProjectFeatureState.swift` with the form's other small types.

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case daemonEvent(DaemonEvent)
    case addNodeButtonTapped(parentBackend: CLISessionBackendKind?)
    /// The lane's origin `+` on the Graph view: a top-level loop, declared an entry
    /// because someone asked for a beginning rather than left one lying around.
    case addEntryLoopTapped
    /// The + handle on a node card: opens the same form, and the created loop gets a
    /// hand-off edge from this node.
    case addChildNodeTapped(UUID)
    /// The context menus' "New Child Loop…": a *custody* child — `createdBy` set, the
    /// daemon draws the already-fired link, the loop starts now. Distinct from
    /// `.addChildNodeTapped` (the + handle), which wires an unfired hand-off that
    /// sequences the new loop *after* the parent — under a long-running parent that
    /// meant a loop blocked indefinitely while its session already ran.
    case newChildLoopTapped(UUID)
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
    /// "Promote to…" on a sketch card: opens the one-field form for the chosen target.
    case promoteNodeRequested(UUID, to: LoopType)
    case promotionConfirmed
    case promotionCancelled
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
    /// Export Loop… on a card: the loop and everything descended from it — child
    /// loops, sub-loops, session memory — packaged into a zip the save panel names.
    case exportNodeRequested(UUID)
    /// Export All Loops… on the canvas background: the whole graph as one bundle.
    case exportGraphRequested
    /// Import Loops… — from a card the bundle arrives as that loop's children; from
    /// the canvas background (`nil`) it arrives beside everything else.
    case importLoopsRequested(asChildOf: UUID?)
    /// The sidebar folder row's Export All Loops…: always the *whole project's* graph,
    /// unlike `exportGraphRequested`, which exports whatever canvas is showing — a
    /// folder row means the folder, whether or not its canvas is parked inside a
    /// composite.
    case projectExportRequested
    /// The sidebar folder row's Import Loops…: lands at the project's top level for
    /// the same reason — the folder was named, not the composite its canvas happens
    /// to be drilled into.
    case projectImportRequested
  }

  @Dependency(\.gitClient) var gitClient
  /// Names an untitled loop after creation — see `createNodeConfirmed`.
  @Dependency(\.titleSuggestionClient) var titleSuggestionClient
  /// Where every project's node names are registered, so a suggested name can be
  /// checked against all of them — not just this project's.
  @Dependency(\.loopTitleDirectory) var loopTitleDirectory

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
          loopTitleDirectory.register(newGraph.project.path, newGraph)
          // Every card placed again from the graph that just arrived, rather than only the
          // ones that are new. Slots handed out at arrival time made the canvas a record of
          // the order loops turned up in: a hand-off drawn between two cards the layout had
          // no reason to put near each other ran behind whatever sat between them, and
          // wiring a graph up changed nothing about how it looked. See `LaneLayout`.
          state.nodePositions = LaneLayout.positions(forCanvas: newGraph)
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
        case .quickChatsListed, .quickChatChanged, .quickChatDeleted, .quickChatActivity:
          break  // Quick chats belong to no project — AppFeature owns them.
        }
        return .none

      case .addNodeButtonTapped(let parentBackend):
        return openNodeForm(&state, backend: parentBackend, parentNodeID: nil)

      case .addEntryLoopTapped:
        return openNodeForm(&state, backend: nil, parentNodeID: nil, declaresEntry: true)

      case .addChildNodeTapped(let parentID):
        // The child inherits its parent's backend, same rule as creating from within an
        // open loop's workspace.
        return openNodeForm(
          &state, backend: state.graph.nodes[id: parentID]?.backend, parentNodeID: parentID)

      case .newChildLoopTapped(let parentID):
        return openNodeForm(
          &state, backend: state.graph.nodes[id: parentID]?.backend, parentNodeID: parentID,
          custodial: true)

      case .cancelNewNodeForm:
        state.showingNewNodeForm = false
        return .none

      case .createNodeConfirmed:
        return confirmCreateNode(&state)

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
        return runDoneCheckTest(&state)

      case .doneCheckTested(let passed, let duration):
        state.isTestingDoneCheck = false
        state.doneCheckOutcome = DoneCheckOutcome(passed: passed, duration: duration)
        return .none

      case .markAsEntryTapped(let nodeID):
        state.declaredEntryIDs.insert(nodeID)
        return .none

      case .exportNodeRequested(let nodeID):
        // Whichever graph actually holds the loop: a canvas card drilled into a
        // composite lives in the sub-graph, while the sidebar names top-level loops
        // regardless of where the canvas is parked — resolving against the canvas
        // alone made the sidebar's Export a silent no-op whenever a composite was
        // open. Memory paths are keyed by the *project*, the same at any depth.
        let graph =
          state.canvasGraph.nodes[id: nodeID] != nil ? state.canvasGraph : state.graph
        guard let node = graph.nodes[id: nodeID] else { return .none }
        return exportBundle(
          from: graph, projectPath: state.graph.project.path,
          nodeIDs: [nodeID], suggestedName: node.title)

      case .exportGraphRequested:
        return exportBundle(
          from: state.canvasGraph, projectPath: state.graph.project.path,
          nodeIDs: nil, suggestedName: state.graph.project.name)

      case .importLoopsRequested(let parentID):
        // Route into the open composite only when the named parent actually lives
        // there (or none was named — a background import targets what you're looking
        // at). A sidebar right-click can name a top-level loop while the canvas is
        // inside a composite, and that import belongs at the top level.
        let compositeID: UUID? =
          if let parentID {
            state.canvasGraph.nodes[id: parentID] != nil ? state.openCompositeID : nil
          } else {
            state.openCompositeID
          }
        return importLoops(
          projectPath: state.graph.project.path, asChildOf: parentID, into: compositeID)

      case .projectExportRequested:
        return exportBundle(
          from: state.graph, projectPath: state.graph.project.path,
          nodeIDs: nil, suggestedName: state.graph.project.name)

      case .projectImportRequested:
        return importLoops(
          projectPath: state.graph.project.path, asChildOf: nil, into: nil)

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
        // The card keeps its place until the broadcast lands, at which point the whole
        // canvas is laid out again without it. Dropping the position here instead would
        // teleport a card that is still on screen to the canvas origin for a frame.
        let projectPath = state.graph.project.path
        return .run { _ in
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .deleteNode(nodeID)))
        }

      case .promoteNodeRequested(let nodeID, let target):
        return openPromotionForm(&state, nodeID: nodeID, target: target)

      case .promotionCancelled:
        state.nodePendingPromotion = nil
        return .none

      case .promotionConfirmed:
        return confirmPromotion(&state)

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
  /// The loop type the form opens on: the last one a loop was actually created with.
  ///
  /// Set at creation rather than at selection — browsing the chooser is not a
  /// preference, pressing Create is. App-side `UserDefaults` like the other UI
  /// memories (`hasSeenOnboarding`, the rail width): which type someone reaches for
  /// is not a setting the daemon or another machine has any use for.
  static let lastLoopTypeKey = "lastCreatedLoopType"

  static var rememberedLoopType: LoopType {
    loopType(remembered: UserDefaults.standard.string(forKey: lastLoopTypeKey))
  }

  /// No remembered choice lands on Sketch — the type that demands nothing decided
  /// yet, which is the honest opening for someone who hasn't expressed a preference.
  /// Landing on any committed type puts a whole form in front of a person who never
  /// picked it. A stored value nothing can decode (an old build's spelling, a
  /// hand-edited defaults write) gets the same treatment as none.
  ///
  /// Composite is filtered on read as well as never written: the key is app-wide and
  /// only form-creates update it, so one composite made months ago in another project
  /// owned every project's form until the next form-create — the "why does this keep
  /// opening on Composite" report. Values written by older builds are exactly why the
  /// write-side skip alone isn't enough.
  static func loopType(remembered raw: String?) -> LoopType {
    let remembered = raw.flatMap(LoopType.init(rawValue:))
    return remembered == .composite ? .sketch : (remembered ?? .sketch)
  }

  /// Resets the promotion form's one field and opens it for the chosen target — only
  /// ever for a sketch; anything already shaped has nothing to promote.
  private func openPromotionForm(
    _ state: inout State, nodeID: UUID, target: LoopType
  ) -> Effect<Action> {
    guard state.graph.nodes[id: nodeID]?.loopType == .sketch else { return .none }
    state.nodePendingPromotion = nodeID
    state.promotionTarget = target
    state.promotionGoal = ""
    state.promotionPausesBeforeWritesOnly = false
    state.promotionInterval = .hourly
    state.promotionCustomInterval = ""
    return .none
  }

  /// Sends the promotion the form currently means; a nil `promotion` (empty required
  /// field) leaves the form up, matching the disabled Promote button beside it.
  private func confirmPromotion(_ state: inout State) -> Effect<Action> {
    guard let nodeID = state.nodePendingPromotion, let promotion = state.promotion
    else { return .none }
    state.nodePendingPromotion = nil
    // `promotedBy: nil` — a human in the app, the same attribution the form's other
    // commands carry.
    return send(state, .promoteNode(nodeID, promotion: promotion, promotedBy: nil))
  }

  /// Resets the draft fields and opens the node form — the shared half of
  /// `.addNodeButtonTapped` and `.addChildNodeTapped`.
  ///
  /// The type defaults to whatever was chosen last (`rememberedLoopType`): someone who
  /// always makes goal loops shouldn't re-pick Goal every time. Goal-based before
  /// anything has been created, because a loop that starts itself and knows when it is
  /// finished is what most work wants, where the old turn-based default made a loop
  /// that sits idle until a human opens it — surprising as the *default* outcome of
  /// Create.
  /// Runs the form's done check exactly the way `graphcoded` will — same evaluator,
  /// same shell, same directory (`GoalDraftFields.testButton`).
  private func runDoneCheckTest(_ state: inout State) -> Effect<Action> {
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
  }

  /// The Create button's whole handler — in the trailing extension beside
  /// `openNodeForm` and the rest of the form's helpers, and for the same reason.
  private func confirmCreateNode(_ state: inout State) -> Effect<Action> {
    let draft = state.draft
    // `isValid` carries the same rules the daemon enforces, so an incomplete form
    // simply doesn't submit — the Create button is disabled on it too, and this is
    // the backstop for the keyboard shortcut path.
    guard draft.isValid else { return .none }
    // Composite is deliberately not remembered: creating one is a rare, structural
    // act, and the *next* loop is almost never another composite — remembering it
    // made the heaviest type the default everywhere (see `loopType(remembered:)`).
    if draft.loopType != .composite {
      UserDefaults.standard.set(draft.loopType.rawValue, forKey: Self.lastLoopTypeKey)
    }
    let projectPath = state.graph.project.path
    // A form opened from a node card's + handle also wires the new loop up: a
    // default hand-off edge from the parent, created right after the node so the
    // graph never broadcasts a child floating unconnected.
    let parentNodeID = state.draftParentNodeID
    let custodial = state.draftParentIsCustodial
    // Asked for from the entry handle, so it is a beginning on purpose — without this it
    // would land as `.unwired`, which the canvas draws dimmed and dashed and offers to
    // fix. See `CardEntryRole`.
    if state.draftDeclaresEntry { state.declaredEntryIDs.insert(draft.id) }
    state.draftDeclaresEntry = false
    state.draftParentNodeID = nil
    state.draftParentIsCustodial = false
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
      // A custody child carries its parent on the draft; the daemon draws the
      // fired-at-birth link and writes the report-back memo, exactly as it does
      // for a CLI-created child. No separate edge command, so nothing blocks.
      if custodial, let parentNodeID { resolved.createdBy = parentNodeID }
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
      if let parentNodeID, !custodial {
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
        let basis = [
          draft.checkDescription, draft.triggerPrompt, draft.goal?.summary,
          draft.firstInstruction,
        ]
        .compactMap({ $0 })
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
        let title = await titleSuggestionClient.suggest(
          draft.effectiveBackend, basis, loopTitleDirectory.allTitles())
      else { return }
      try? await orchestratorClient.send(
        .graphCommand(
          projectPath: projectPath, command: addressed(.renameNode(draft.id, title: title))))
    }
  }

  private func openNodeForm(
    _ state: inout State, backend: CLISessionBackendKind?, parentNodeID: UUID?,
    custodial: Bool = false, declaresEntry: Bool = false
  ) -> Effect<Action> {
    state.draftID = UUID()
    state.draftDeclaresEntry = declaresEntry
    state.draftLoopType = Self.rememberedLoopType
    state.draftTitle = ""
    state.draftCheck = ""
    state.draftPrompt = ""
    state.draftGoal = ""
    state.draftPredicate = ""
    state.draftMetric = ""
    state.draftMetricDirection = .maximize
    state.isMetricExpanded = false
    state.draftBudget = ""
    state.isBudgetExpanded = false
    state.doneCheckOutcome = nil
    state.isTestingDoneCheck = false
    state.draftFirstInstruction = ""
    state.draftPausesBeforeWritesOnly = false
    state.draftSketchNote = ""
    state.draftInterval = .hourly
    // While the experiment is on, the daemon heartbeat is the *default* for new timed
    // loops — the /loop skill runs only when a person explicitly picks "Itself, with
    // /loop" in the form. The toggle governing a default rather than mere availability
    // is a deliberate, user-directed reversal of the earlier converts-nothing stance;
    // existing loops are still never converted. Same settings read the defaultBackend
    // line below already does.
    state.draftUsesHeartbeat = GraphcodeSettingsStore.load().daemonHeartbeatEnabled
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
    state.draftParentIsCustodial = custodial
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

  /// Open panel → bundle → daemon import, shared by every Import Loops… entry point:
  /// a card (parent set, lands under it), the canvas background (parent nil, lands in
  /// whatever graph the canvas shows), and the sidebar folder row (parent and
  /// composite both nil — the folder was named, so the project's top level is where
  /// the loops belong).
  private func importLoops(
    projectPath: String, asChildOf parentID: UUID?, into compositeID: UUID?
  ) -> Effect<Action> {
    .run { _ in
      let request = await MainActor.run { () -> GraphImportRequest? in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GraphCode export bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundle = GraphExportBundle.readFromZip(at: url.path) else { return nil }
        // Re-identifies and installs any carried sessions under the fresh ids, so
        // an imported loop resumes its exported conversation on first open.
        return bundle.preparedImportRequest(asChildOf: parentID, projectPath: projectPath)
      }
      guard let request else { return }
      let command = GraphCommand.importNodes(request)
      try? await orchestratorClient.send(
        .graphCommand(
          projectPath: projectPath,
          command: compositeID.map { .subGraphCommand(nodeID: $0, command: command) }
            ?? command))
    }
  }

  /// Save panel → bundle → zip, shared by the card's Export Loop… (`nodeIDs` names the
  /// loop, descendants ride along) and the background's Export All Loops… (`nil`).
  ///
  /// Export is read-only, so unlike import it never goes near the daemon: the graph in
  /// hand is the daemon's own latest broadcast, and memory logs are read straight off
  /// disk. The finished zip is revealed in Finder — that reveal *is* the success
  /// feedback, pointing at the file the user is about to go share.
  private func exportBundle(
    from graph: LoopGraph, projectPath: String, nodeIDs: [UUID]?, suggestedName: String
  ) -> Effect<Action> {
    .run { _ in
      await MainActor.run {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue =
          suggestedName.replacingOccurrences(of: "/", with: "-") + ".zip"
        panel.message = "Export loops as a shareable bundle"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let persistence = ProjectPersistence(baseDirectory: SupportDirectory.url)
        let bundle: GraphExportBundle? =
          if let nodeIDs {
            persistence.createExportBundle(
              for: nodeIDs, from: graph, projectPath: projectPath, createdBy: NSUserName())
          } else {
            persistence.createFullGraphExportBundle(
              for: graph, projectPath: projectPath, createdBy: NSUserName())
          }
        guard let bundle, bundle.writeToZip(at: url.path) != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
  }

}
