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
    var showingNewNodeForm = false
    var draftLoopType: LoopType = .turnBased
    var draftTitle = ""
    var draftCheck = ""
    var draftPrompt = ""
    var draftGoal = ""
    var draftPredicate = ""
    var draftBackend: CLISessionBackendKind = .claudeCode
    var draftWorktree: WorktreeSelection = .none
    var draftBranch = ""
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

    var id: String { graph.project.path }

    init(graph: LoopGraph) {
      self.graph = graph
    }
  }

  /// Which `PayloadTransform` case the edge editor's picker is on. A sibling of
  /// `PendingEdge` rather than nested inside it only to keep nesting one level deep.
  enum TransformMode: String, CaseIterable, Equatable {
    case none, template, script

    var displayName: String {
      switch self {
      case .none: return "Nothing"
      case .template: return "Text"
      case .script: return "Script"
      }
    }
  }

  /// An edge the human has drawn but not yet configured. Holds the draft `EdgeSpec`
  /// directly so the editor's controls bind straight to what gets sent — no separate
  /// pile of `draftEdge*` fields to keep in sync.
  struct PendingEdge: Equatable, Identifiable {
    let from: UUID
    let to: UUID
    var spec = EdgeSpec()
    /// Which `PayloadTransform` case the picker is on. Kept alongside the text so
    /// switching template↔script doesn't discard what was already typed.
    var transformMode: TransformMode = .none
    var transformText = ""
    /// Off by default. Turning it on is what lets the edge fire more than once, and it
    /// can't be turned on without a bound — see `CycleGuard`.
    var loops = false
    var maxIterations = 3
    var untilCommand = ""

    var id: String { "\(from)->\(to)" }

    /// The spec actually sent, with the transform folded in from the picker + text.
    var resolvedSpec: EdgeSpec {
      var spec = self.spec
      let text = transformText.trimmingCharacters(in: .whitespacesAndNewlines)
      switch transformMode {
      case .none: spec.payloadTransform = .none
      case .template: spec.payloadTransform = text.isEmpty ? .none : .template(text)
      case .script: spec.payloadTransform = text.isEmpty ? .none : .script(text)
      }
      spec.cycleGuard = loops ? cycleGuard : nil
      return spec
    }

    /// The iteration cap always travels with a looping edge, even when an `until`
    /// command is set. Two independent bounds is the conservative reading of docs/08 —
    /// a predicate that never comes true shouldn't mean an unbounded loop.
    var cycleGuard: CycleGuard {
      CycleGuard(
        maxIterations: max(1, maxIterations),
        until: untilCommand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : untilCommand)
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case daemonEvent(DaemonEvent)
    case addNodeButtonTapped
    case createNodeConfirmed
    case cancelNewNodeForm
    case nodeTapped(UUID)
    case edgeDrawn(from: UUID, to: UUID)
    case createEdgeConfirmed
    case cancelEdgeForm
    case deleteNodeRequested(UUID)
    case deleteNodeConfirmed
    case deleteNodeCancelled
    case deleteEdgeTapped(UUID)
    case stopNodeTapped(UUID)
    case pilotCompositeTapped(UUID)
    case armCompositeTapped(UUID)
    case refreshUsageTapped
    case worktreesLoaded([WorktreeRef])
    case worktreeCreationFailed(String)
  }

  @Dependency(\.gitClient) var gitClient

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
          for node in newGraph.nodes where state.nodePositions[node.id] == nil {
            let position = Self.nextFreePosition(avoiding: taken)
            taken.insert(position)
            state.nodePositions[node.id] = position
          }
          state.graph = newGraph
        case .errorOccurred(let message):
          state.connectionError = message
        case .recentProjectsListed:
          break  // Not this feature's concern — AppFeature routes this to `welcome`.
        }
        return .none

      case .addNodeButtonTapped:
        state.draftLoopType = .turnBased
        state.draftTitle = ""
        state.draftCheck = ""
        state.draftPrompt = ""
        state.draftGoal = ""
        state.draftPredicate = ""
        // The human's default, not a hardcoded one (Settings → Sessions).
        state.draftBackend = GraphcodeSettingsStore.load().defaultBackend
        state.draftWorktree = .none
        state.draftBranch = ""
        state.showingNewNodeForm = true
        let repositoryPath = state.graph.project.path
        return .run { send in
          // A non-repo folder just yields nothing — a missing worktree list is not worth
          // an error banner when the picker degrades to "None" on its own.
          let worktrees = (try? await gitClient.listWorktrees(repositoryPath)) ?? []
          await send(.worktreesLoaded(worktrees))
        }

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
        state.showingNewNodeForm = false

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
          try? await orchestratorClient.send(
            .graphCommand(projectPath: projectPath, command: .createNode(resolved)))
        }

      case .worktreeCreationFailed(let message):
        state.connectionError = "Couldn't create worktree: \(message)"
        return .none

      case .worktreesLoaded(let worktrees):
        state.availableWorktrees = worktrees
        return .none

      case .nodeTapped:
        // Handled by `AppFeature`'s parent `Reduce`, which owns cross-project
        // selection — nothing to do here.
        return .none

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
