import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The New Node dialog's reducer half: opening the form with every field at its default,
/// and turning what was filled in into the commands that create the loop.
///
/// Split out of `ProjectFeature.swift`, which sits at swiftlint's file-length budget, so
/// that the dialog's own code has somewhere to grow. A straight move — see git history
/// for what changed.
extension ProjectFeature {
  /// The Create button's whole handler — in the trailing extension beside
  /// `openNodeForm` and the rest of the form's helpers, and for the same reason.
  func confirmCreateNode(_ state: inout State) -> Effect<Action> {
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
    // The directory watch belongs to the open dialog, not to the store — creating a
    // loop closes the form just as Cancel does, and leaving it running would keep
    // re-reading the library for a form nobody is looking at.
    let closedWatch = Effect<Action>.cancel(id: CancelID.templateWatch)
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
    return .merge(
      closedWatch,
      .run { send in
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

        // A blank title creates the node as "NewNode" and asks the loop's own
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
      })
  }

  func openNodeForm(
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
    state.draftAttachments = DraftAttachments()
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
    state.draftSubGraph = nil
    // The parent's backend when there is one, then the open composite's — its workers
    // run on what it runs on — and the human's default otherwise (Settings → Sessions),
    // never a hardcoded one.
    state.draftBackend =
      backend ?? state.openCompositeID.flatMap { state.graph.nodes[id: $0]?.backend }
      ?? GraphcodeSettingsStore.load().defaultBackend
    let settings = GraphcodeSettingsStore.load()
    state.draftModelTier = settings.autoSelectsModel ? nil : settings.defaultModelTier
    state.draftWorktree = .none
    state.draftBranch = ""
    state.draftParentNodeID = parentNodeID
    state.draftParentIsCustodial = custodial
    state.templates = TemplateFormState()
    state.showingNewNodeForm = true
    let repositoryPath = state.graph.project.path
    return .merge(
      .run { send in
        // A non-repo folder just yields nothing — a missing worktree list is not worth
        // an error banner when the picker degrades to "None" on its own.
        let worktrees = (try? await gitClient.listWorktrees(repositoryPath)) ?? []
        await send(.worktreesLoaded(worktrees))
      },
      // The template library rides in with the form: read once, then kept current by
      // the directory watch, so an external edit or a `git pull` shows up without a
      // relaunch (PROMPT_TEMPLATES.md § Storage).
      .run { send in
        await send(.templateLibraryChanged(await templateLibrary.load(repositoryPath)))
      },
      .run { [projectPath = repositoryPath] send in
        for await _ in templateLibrary.watch(projectPath) {
          await send(.templateLibraryChanged(await templateLibrary.load(projectPath)))
        }
      }
      .cancellable(id: CancelID.templateWatch, cancelInFlight: true)
    )
  }
}
