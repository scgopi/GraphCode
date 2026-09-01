import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The template feature's reducer half — everything ⌘T's picker, the applied
/// state and Save-as-template do to the draft. Lives beside `ProjectFeature` the
/// way the form's other helpers do: applying a template is a mutation on the
/// existing `NodeDraft`, never a second draft type (PROMPT_TEMPLATES.md §
/// Implementation notes).
extension ProjectFeature {
  /// Which fields the template set — the "from template" dots on the form, and
  /// the boundary `Undo the shape` and ✕ revert along.
  enum TemplateFieldKey: String, Equatable, CaseIterable, Sendable {
    case brief
    case shape
    case title
    case backend
    case doneCheck
    case cadence
    case pausesBeforeWritesOnly
    case branch
    case metric
    case subGraph
  }

  /// The template currently shaping the form, with everything un-applying needs:
  /// what it set, and the fields as they were before it landed. Held rather than
  /// re-derived so the ✕ can restore a draft the human has since edited — the
  /// restore answers "what did this template change", not "what does the form
  /// hold now".
  struct AppliedTemplate: Equatable {
    let id: UUID
    let name: String
    let shape: LoopType?
    var setFields: Set<TemplateFieldKey>
    var snapshot: DraftSnapshot
    /// The brief as the template carries it, `{token}` holes and all — what Save
    /// compares the human's filled text against to offer the values back as
    /// tokens (PROMPT_TEMPLATES.md § Save as template).
    var brief: String

    /// Whether the template carried a shape or any setting — the applied strip
    /// and its "Undo the shape" only exist when something beyond the text landed.
    var carriesShape: Bool {
      setFields.contains(.shape)
        || !setFields.isDisjoint(with: [
          .backend, .doneCheck, .cadence, .pausesBeforeWritesOnly, .branch, .metric, .subGraph,
        ])
    }
  }

  /// The form's fields as they were before a template landed — the ✕ restore.
  /// Deliberately every field a template *could* touch, so one snapshot serves
  /// every apply, and nothing about the restore depends on which fields this
  /// particular template happened to set.
  struct DraftSnapshot: Equatable {
    var loopType: LoopType
    var title: String
    var sketchNote: String
    var goal: String
    var predicate: String
    var metric: String
    var metricDirection: MetricDirection
    var isMetricExpanded: Bool
    var firstInstruction: String
    var pausesBeforeWritesOnly: Bool
    var timedTask: String
    var interval: IntervalChoice
    var customInterval: String
    var stopAfter: String
    var schedule: CompositeSchedule
    var scheduleTime: String
    var backend: CLISessionBackendKind
    var worktree: WorktreeSelection
    var branch: String
    var subGraph: LoopGraph?
  }

  // MARK: - The template switches

  /// The ⌘T picker: opening it, searching it, walking it, closing it. Split from the
  /// two switches below so each stays a switch about one thing — the whole family in
  /// one function was a single 20-branch reducer that no reader could hold.
  /// Non-template actions pass through untouched.
  func templatePickerReducer(
    _ state: inout State, _ action: Action
  ) -> Effect<Action> {
    switch action {
    case .templatesButtonTapped:
      state.templates.isPickerOpen = true
      state.templates.query = ""
      // The row ⏎ would take is the first one, so the keys work before the mouse
      // does — and ⌘⏎'s "start now" offer reads from the same selection.
      state.templates.selectionIndex = 0
      // The library is re-read on open, not only when the form opened: an edit
      // between the two moments, or a watcher that never got to fire, shows up
      // the moment ⌘T is pressed.
      let projectPath = state.graph.project.path
      let library = templateLibrary
      return .run { send in
        await send(.templateLibraryChanged(await library.load(projectPath)))
      }

    case .templatePickerClosed:
      state.templates.isPickerOpen = false
      return .none

    case .templateQueryChanged(let query):
      state.templates.query = query
      state.templates.selectionIndex = 0
      return .none

    case .templateSelectionMoved(let offset):
      let count = state.templatePickerRows.count
      guard count > 0 else { return .none }
      let current = state.templates.selectionIndex ?? -1
      state.templates.selectionIndex = min(max(current + offset, 0), count - 1)
      return .none

    case .templateLibraryChanged(let templates):
      state.templates.library = templates
      return .none

    default:
      return .none
    }
  }

  /// What a chosen template does to the draft, and how it is taken back — the
  /// applied state (PROMPT_TEMPLATES.md § Applied state).
  func templateApplyReducer(
    _ state: inout State, _ action: Action
  ) -> Effect<Action> {
    switch action {
    case .templateTokenJumpRequested:
      // ⇥ walks the fields still holding a hole, cycling from wherever it last
      // landed — a token in a done check is as much a hole as one in the brief.
      let fields = state.tokenFields
      guard let first = fields.first else { return .none }
      guard let current = state.templates.focusRequest,
        let index = fields.firstIndex(of: current)
      else {
        state.templates.focusRequest = first
        return .none
      }
      state.templates.focusRequest = fields[(index + 1) % fields.count]
      return .none

    case .templateFocusConsumed:
      state.templates.focusRequest = nil
      return .none

    case .templateChosen(let id):
      guard let template = state.templates.library.first(where: { $0.id == id }) else {
        return .none
      }
      state.templates.isPickerOpen = false
      applyTemplate(&state, template)
      state.templates.focusRequest = .brief
      return countUse(of: template, in: state.graph.project.path)

    case .templateLaunched(let id):
      guard let template = state.templates.library.first(where: { $0.id == id }) else {
        return .none
      }
      state.templates.isPickerOpen = false
      applyTemplate(&state, template)
      let counted = countUse(of: template, in: state.graph.project.path)
      // ⌘⏎ is "start now", and a brief with a hole in it is not one: the same
      // unfilled-token gate the Create button obeys. The fill still happened, so the
      // human lands on the brief with the holes to fill, exactly as ⏎ leaves them.
      guard state.unfilledTokens.isEmpty, state.draft.isValid else {
        state.templates.focusRequest = .brief
        return counted
      }
      return .merge(counted, confirmCreateNode(&state))

    case .templateChipRemoved:
      restoreDraft(&state, from: state.templates.applied?.snapshot)
      state.templates.applied = nil
      return .none

    case .templateShapeUndone:
      return undoTemplateShape(&state)

    case .detachTemplateTapped(let nodeID):
      let projectPath = state.graph.project.path
      return .run { _ in
        try? await orchestratorClient.send(
          .graphCommand(projectPath: projectPath, command: .detachTemplate(nodeID)))
      }

    default:
      return .none
    }
  }

  // MARK: - Applying

  /// One template, one mutation on the fields the form already edits. Every field
  /// the template sets is recorded in `setFields` — that is what draws the
  /// "from template" dot and what ✕ and `Undo the shape` revert along.
  func applyTemplate(_ state: inout State, _ template: PromptTemplate) {
    // Applying a second template keeps the *first* one's snapshot: ✕ answers "put the
    // form back the way I found it", and the way the human found it is before any
    // template landed, not before the most recent one.
    let restorePoint = state.templates.applied?.snapshot ?? snapshot(of: &state)
    state.templates.applied = AppliedTemplate(
      id: template.id, name: template.name, shape: template.shape,
      setFields: [], snapshot: restorePoint, brief: template.body)
    var set: Set<TemplateFieldKey> = []
    set.formUnion(applyBrief(&state, template))
    set.formUnion(applyShape(&state, template))
    set.formUnion(applySettings(&state, template))
    if template.shape == .composite, state.draftTitle.isEmpty {
      set.insert(.title)
      state.draftTitle = template.name
    }
    state.templates.applied?.setFields = set
  }

  /// The brief lands in the type's own field — Main's starting note, Goal's
  /// "what does done look like", Timed's "what to do each time", Turn's first
  /// instruction. Composite's brief is its name.
  private func applyBrief(
    _ state: inout State, _ template: PromptTemplate
  ) -> Set<TemplateFieldKey> {
    guard !template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    switch template.shape {
    case .sketch, nil: state.draftSketchNote = template.body
    case .goalBased: state.draftGoal = template.body
    case .timeBased: state.draftTimedTask = template.body
    case .turnBased: state.draftFirstInstruction = template.body
    case .composite:
      // A composite's brief is its name (the form has no prose field for it), and the
      // name is set from the template separately. Nothing landed here, so nothing is
      // marked — a "from template" dot on a field this didn't write would be a lie.
      return []
    }
    return [.brief]
  }

  /// The shape the loop takes on, and the one rule `runsAs`'s onChange applies
  /// with it — a type the chosen agent can't host falls back to one it can.
  private func applyShape(
    _ state: inout State, _ template: PromptTemplate
  ) -> Set<TemplateFieldKey> {
    // A shapeless template means Main (PROMPT_TEMPLATES.md § What a template
    // carries) — the form follows, and the switch is the shape it set, so Undo
    // can put the form back where it was.
    let resolvedShape = template.shape ?? (state.draftLoopType == .sketch ? nil : .sketch)
    guard let shape = resolvedShape, shape != state.draftLoopType else { return [] }
    state.draftLoopType = shape
    if !state.draftBackend.canHost(shape) {
      state.draftBackend = CLISessionBackendKind.hosting(shape).first ?? .claudeCode
    }
    return [.shape]
  }

  /// Everything but the prompt, each landing in its *real* dialog field. The agent
  /// and the branch are honest in any shape — where the loop runs and where it works
  /// are not what the loop *is* — so they sit here; everything else is the type's own
  /// and lives in `applyShapeSettings`.
  private func applySettings(
    _ state: inout State, _ template: PromptTemplate
  ) -> Set<TemplateFieldKey> {
    guard let settings = template.settings else { return [] }
    var set: Set<TemplateFieldKey> = []
    if let backend = settings.backend {
      set.insert(.backend)
      state.draftBackend = backend
    }
    set.formUnion(applyShapeSettings(&state, shape: template.shape, settings: settings))
    set.formUnion(applyBranch(&state, settings: settings))
    return set
  }

  /// The settings only one loop type has a field for.
  private func applyShapeSettings(
    _ state: inout State, shape: LoopType?, settings: TemplateSettings
  ) -> Set<TemplateFieldKey> {
    switch shape {
    case .goalBased:
      var set: Set<TemplateFieldKey> = []
      if let check = settings.doneCheck {
        set.insert(.doneCheck)
        state.draftPredicate = check
      }
      if let metric = settings.metric {
        set.insert(.metric)
        state.draftMetric = metric
        state.isMetricExpanded = true
      }
      return set
    case .timeBased:
      return applyCadence(&state, settings.cadence)
    case .turnBased:
      guard let pauses = settings.pausesBeforeWritesOnly else { return [] }
      state.draftPausesBeforeWritesOnly = pauses
      return [.pausesBeforeWritesOnly]
    case .composite:
      guard let graph = settings.carriedGraph, !graph.nodes.isEmpty else { return [] }
      state.draftSubGraph = graph.reIdentified()
      return [.subGraph]
    case .sketch, nil:
      return []
    }
  }

  /// The five-segment interval control when the template's cadence is one of them,
  /// Custom… with the value typed in when it isn't.
  private func applyCadence(
    _ state: inout State, _ raw: String?
  ) -> Set<TemplateFieldKey> {
    guard let cadence = raw?.trimmingCharacters(in: .whitespaces), !cadence.isEmpty else {
      return []
    }
    if let choice = IntervalChoice.allCases.first(where: {
      $0 != .custom && $0.directiveValue(custom: "") == cadence
    }) {
      state.draftInterval = choice
      state.draftCustomInterval = ""
    } else {
      state.draftInterval = .custom
      state.draftCustomInterval = cadence
    }
    return [.cadence]
  }

  /// Hidden for a remote project or the global graph, exactly where the form itself
  /// hides the branch picker — a template must not set a field nobody can see.
  private func applyBranch(
    _ state: inout State, settings: TemplateSettings
  ) -> Set<TemplateFieldKey> {
    guard let branch = settings.branch, !branch.isEmpty, !state.graph.isGlobal,
      RemoteProjectLocation.parse(projectPath: state.graph.project.path) == nil
    else { return [] }
    state.draftWorktree = .newBranch
    state.draftBranch = branch
    return [.branch]
  }

  /// "Undo the shape": type and settings revert, the prompt text stays, the loop
  /// returns to Main. The brief travels with it — text sitting in a Goal field
  /// becomes the Main note, because "keep just the prompt" means the prompt.
  func undoTemplateShape(_ state: inout State) -> Effect<Action> {
    guard let applied = state.templates.applied, applied.carriesShape else { return .none }
    let keptText = state.currentBriefText
    restoreDraft(&state, from: applied.snapshot)
    state.draftLoopType = .sketch
    state.draftSketchNote = keptText
    state.templates.applied?.setFields = [.brief]
    return .none
  }

  /// Puts every snapshotable field back. The ✕ path passes the applied template's
  /// snapshot; other callers pass nothing and clear the rest of the template
  /// state themselves.
  func restoreDraft(_ state: inout State, from snapshot: DraftSnapshot?) {
    guard let snapshot else {
      // No snapshot means there was never a shape to revert — a Main template's
      // ✕ clears only its text.
      state.draftSketchNote = ""
      state.draftGoal = ""
      state.draftTimedTask = ""
      state.draftFirstInstruction = ""
      state.draftPredicate = ""
      state.draftMetric = ""
      state.isMetricExpanded = false
      state.draftInterval = .hourly
      state.draftCustomInterval = ""
      state.draftPausesBeforeWritesOnly = false
      state.draftBackend = GraphcodeSettingsStore.load().defaultBackend
      state.draftWorktree = .none
      state.draftBranch = ""
      state.draftSubGraph = nil
      return
    }
    state.draftLoopType = snapshot.loopType
    state.draftTitle = snapshot.title
    state.draftSketchNote = snapshot.sketchNote
    state.draftGoal = snapshot.goal
    state.draftPredicate = snapshot.predicate
    state.draftMetric = snapshot.metric
    state.draftMetricDirection = snapshot.metricDirection
    state.isMetricExpanded = snapshot.isMetricExpanded
    state.draftFirstInstruction = snapshot.firstInstruction
    state.draftPausesBeforeWritesOnly = snapshot.pausesBeforeWritesOnly
    state.draftTimedTask = snapshot.timedTask
    state.draftInterval = snapshot.interval
    state.draftCustomInterval = snapshot.customInterval
    state.draftStopAfter = snapshot.stopAfter
    state.draftSchedule = snapshot.schedule
    state.draftScheduleTime = snapshot.scheduleTime
    state.draftBackend = snapshot.backend
    state.draftWorktree = snapshot.worktree
    state.draftBranch = snapshot.branch
    state.draftSubGraph = snapshot.subGraph
  }

  private func snapshot(of state: inout State) -> DraftSnapshot {
    DraftSnapshot(
      loopType: state.draftLoopType,
      title: state.draftTitle,
      sketchNote: state.draftSketchNote,
      goal: state.draftGoal,
      predicate: state.draftPredicate,
      metric: state.draftMetric,
      metricDirection: state.draftMetricDirection,
      isMetricExpanded: state.isMetricExpanded,
      firstInstruction: state.draftFirstInstruction,
      pausesBeforeWritesOnly: state.draftPausesBeforeWritesOnly,
      timedTask: state.draftTimedTask,
      interval: state.draftInterval,
      customInterval: state.draftCustomInterval,
      stopAfter: state.draftStopAfter,
      schedule: state.draftSchedule,
      scheduleTime: state.draftScheduleTime,
      backend: state.draftBackend,
      worktree: state.draftWorktree,
      branch: state.draftBranch,
      subGraph: state.draftSubGraph)
  }

}
