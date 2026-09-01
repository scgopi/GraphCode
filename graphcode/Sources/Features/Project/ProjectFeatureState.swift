import ComposableArchitecture
import Foundation
import GraphcodeKit

/// `ProjectFeature.State`'s derived values — what the form currently means, which loops
/// want a human, and the worktree the form is about to create. Split out of
/// `ProjectFeature` purely for size; they're all pure functions of the state's stored
/// fields, deliberately computed rather than cached so nothing can disagree with the
/// graph the daemon broadcast.
extension ProjectFeature.State {
  /// Which of this project's loops want a human — the same rollup the sidebar's monitor
  /// shows, scoped to this graph so the canvas can mark them
  /// (docs/06-ux-terminals.md#graph-canvas) without a second opinion about what
  /// "needs attention" means.
  ///
  /// Items rather than a `[UUID: AttentionReason]` dictionary: the canvas needs both —
  /// the dictionary to tint cards, the list for its rail — and one rollup read twice is
  /// the difference between this and a second opinion. `ProjectCanvasView.Derived` does
  /// the reading; see the performance contract on its `body`.
  var attentionItems: [AttentionItem] {
    AttentionRollup.fullRollup(across: [graph])
  }

  /// What the canvas draws: the open composite's own sub-graph when one is open, this
  /// project's graph otherwise. Swapping what the canvas *is* rather than pushing a
  /// second view keeps one set of cards, edges, gestures and forms — a composite's
  /// contents are loops like any other, and deserve the same canvas.
  ///
  /// Falls back to the project graph rather than trapping when the id no longer resolves,
  /// so a composite deleted underneath an open canvas leaves you somewhere real.
  var canvasGraph: LoopGraph {
    guard let id = openCompositeID, let subGraph = graph.nodes[id: id]?.subGraph
    else { return graph }
    return subGraph
  }

  /// The composite whose canvas is open, for the breadcrumb that offers the way back out.
  var openComposite: LoopNode? {
    openCompositeID.flatMap { graph.nodes[id: $0] }
  }

  /// The form's fields as the value actually sent. Built on demand rather than kept
  /// alongside the fields, so there's exactly one definition of what the form means.
  var draft: NodeDraft {
    NodeDraft(
      id: draftID,
      title: draftTitle,
      loopType: draftLoopType,
      checkDescription: draftLoopType == .turnBased ? draftCheck : nil,
      triggerPrompt: composedTriggerPrompt,
      heartbeatIntervalSeconds: draftLoopType == .timeBased && effectiveDraftUsesHeartbeat
        ? draftHeartbeatSeconds : nil,
      firstInstruction: {
        switch draftLoopType {
        case .turnBased: return draftFirstInstruction
        case .sketch: return draftSketchNote.isEmpty ? nil : draftSketchNote
        case .goalBased, .timeBased, .composite: return nil
        }
      }(),
      pausesBeforeWritesOnly: draftLoopType == .turnBased && draftPausesBeforeWritesOnly,
      goal: draftLoopType == .goalBased
        ? GoalSpec(
          summary: draftGoal,
          predicate: draftPredicate.isEmpty ? nil : draftPredicate,
          metricCommand: draftMetric.isEmpty ? nil : draftMetric,
          metricDirection: draftMetricDirection,
          tokenBudget: parsedBudget)
        : nil,
      backend: draftBackend,
      // Only an *existing* worktree can be bound here; a new one has to be created on
      // disk first, which is `.createNodeConfirmed`'s job.
      worktree: {
        if case .existing(let ref) = draftWorktree { return ref }
        return nil
      }(),
      subGraph: draftLoopType == .composite ? draftSubGraph : nil,
      // Attribution only — the card can say where the brief came from. The follow
      // travels too, for the two types that follow: timed and composite re-read the
      // template on their next run; goal, turn and main snapshot at creation.
      createdFromTemplateID: templates.applied?.id,
      templateFollow: {
        guard let applied = templates.applied,
          draftLoopType == .timeBased || draftLoopType == .composite
        else { return nil }
        return TemplateFollow(id: applied.id, name: applied.name)
      }())
  }

  /// The budget field as a number, or nil — a blank field, a typo, or a zero all mean
  /// "no budget", never a budget of garbage. Mirrors `GoalSpec.effectivePredicate`'s
  /// reading of an all-whitespace field.
  var parsedBudget: Int? {
    guard let value = Int(draftBudget.trimmingCharacters(in: .whitespaces)), value > 0
    else { return nil }
    return value
  }

  // MARK: - Templates (New Designs v4)

  /// The field currently holding the template brief — the one `{token}` patterns
  /// are looked for in, and the one Save-as-template reads.
  var currentBriefText: String {
    switch draftLoopType {
    case .sketch: return draftSketchNote
    case .goalBased: return draftGoal
    case .timeBased: return draftTimedTask
    case .turnBased: return draftFirstInstruction
    case .composite: return draftTitle
    }
  }

  /// Which of the applied template's `{token}`s is still a hole. A token the human
  /// has typed over is gone as text and so is the hole.
  ///
  /// Every field a template can land in, not only the brief: a done check reading
  /// `make test-{suite}` is exactly as unfinished as a brief with a hole in it, and
  /// starting the loop would run the literal text.
  var unfilledTokens: [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for field in ProjectFeature.TemplateTokenField.allCases {
      for token in PromptTemplate.tokens(in: tokenFieldText(field))
      where seen.insert(token).inserted {
        ordered.append(token)
      }
    }
    return ordered
  }

  /// The design's own line: "One token left to fill · ⇥ to jump to it".
  var unfilledTokenPrompt: String? {
    let count = unfilledTokens.count
    guard count > 0 else { return nil }
    return count == 1
      ? "One token left to fill · ⇥ to jump to it"
      : "\(count) tokens left to fill · ⇥ to jump to them"
  }

  /// What the applied template set — the "from template" dots read this. A
  /// property, not a method, because a store's members are reachable through
  /// key-path lookup only.
  var templateSetFields: Set<ProjectFeature.TemplateFieldKey> {
    templates.applied?.setFields ?? []
  }

  /// Whether the dialog's primary action is ready beyond `draft.isValid` — a
  /// brief with an unfilled token blocks Start, PROMPT_TEMPLATES.md § What a
  /// template carries.
  var draftBlocksOnTokens: Bool {
    !unfilledTokens.isEmpty
  }

  /// The picker's rows, already grouped: **This project** first, then **All
  /// projects**, each sorted by name. The query filters on name and body — a
  /// template is findable by what it says, not only by what it is called.
  var templatePickerRows: [ProjectFeature.TemplatePickerRow] {
    let query = templates.query.trimmingCharacters(in: .whitespaces).lowercased()
    let matches: (PromptTemplate) -> Bool = { template in
      query.isEmpty
        || template.name.lowercased().contains(query)
        || template.body.lowercased().contains(query)
    }
    var project: [PromptTemplate] = []
    var starters: [PromptTemplate] = []
    var mine: [PromptTemplate] = []
    for template in templates.library where matches(template) {
      if template.origin.isProject {
        project.append(template)
      } else if template.isStarter {
        starters.append(template)
      } else {
        mine.append(template)
      }
    }
    func byName(_ templates: [PromptTemplate]) -> [PromptTemplate] {
      templates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    // The shipped ones keep their shipped order: the Starters group is a ladder —
    // lead a team, then Goal, then Timed, then the rest — and alphabetical would
    // scramble it. Everything a person wrote sorts by name, as before.
    let byPriority = starters.sorted {
      StarterTemplates.priority(of: $0.id) < StarterTemplates.priority(of: $1.id)
    }
    return byName(project).map { ProjectFeature.TemplatePickerRow(template: $0, scope: .project) }
      + byPriority.map { ProjectFeature.TemplatePickerRow(template: $0, scope: .starter) }
      + byName(mine).map { ProjectFeature.TemplatePickerRow(template: $0, scope: .home) }
  }

  /// The fields still holding a `{token}`, in the order `⇥` walks them — the order
  /// they appear in the form, so tabbing reads down the dialog.
  var tokenFields: [ProjectFeature.TemplateTokenField] {
    ProjectFeature.TemplateTokenField.allCases.filter {
      !PromptTemplate.tokens(in: tokenFieldText($0)).isEmpty
    }
  }

  func tokenFieldText(_ field: ProjectFeature.TemplateTokenField) -> String {
    switch field {
    case .brief: return currentBriefText
    case .doneCheck: return draftPredicate
    case .metric: return draftMetric
    case .branch: return draftBranch
    }
  }

  /// The starters offered on an empty canvas: the shipped picks, in the order
  /// `StarterTemplates` names them, and only the ones still on disk — a starter
  /// somebody deleted is not offered back to them.
  var firstLaunchStarters: [PromptTemplate] {
    StarterTemplates.firstLaunchPicks.compactMap { pick in
      templates.library.first { $0.id == pick.id }
    }
  }

  var hasProjectTemplates: Bool {
    templates.library.contains(where: \.origin.isProject)
  }

  /// What a timed loop's session actually opens with, composed rather than typed.
  ///
  /// The old form had one free-text field whose placeholder was the whole documentation:
  /// you had to know that the cadence lives *inside* the prompt as a `/loop` directive
  /// (see `LoopNode.triggerPrompt`) and what the syntax was. GraphCode knows both, so it
  /// writes that part and the human writes the work.
  ///
  /// A composite carries its intended schedule here instead — nothing runs at creation,
  /// so it is a statement of intent until the thing is piloted and armed.
  var composedTriggerPrompt: String? {
    switch draftLoopType {
    case .timeBased:
      let task = draftTimedTask.trimmingCharacters(in: .whitespaces)
      guard !task.isEmpty else { return nil }
      // Heartbeat mode: the daemon holds the timer, so the prompt is the bare task —
      // `LoopNode.sessionPrompt` wraps it in the who-holds-the-timer framing at
      // launch. No /loop, and no "Stop after": a heartbeat loop runs until stopped.
      if effectiveDraftUsesHeartbeat { return task }
      var directive = "/loop \(draftInterval.directiveValue(custom: draftCustomInterval)) \(task)"
      let stop = draftStopAfter.trimmingCharacters(in: .whitespaces)
      if !stop.isEmpty { directive += " Stop after \(stop)." }
      return directive
    case .composite:
      return "Intended schedule: \(draftSchedule.summary(at: draftScheduleTime))"
    case .sketch, .goalBased, .turnBased:
      return nil
    }
  }

  /// The mono line the dialog shows under the interval control, so what will be written
  /// is visible before it is written.
  var triggerPreview: String {
    let showsHeartbeat =
      draftLoopType == .timeBased && effectiveDraftUsesHeartbeat
      && !draftTimedTask.trimmingCharacters(in: .whitespaces).isEmpty
    if showsHeartbeat {
      let interval = draftInterval.directiveValue(custom: draftCustomInterval)
      return "[graphcode] heartbeat every \(interval) — the daemon holds the timer"
    }
    return composedTriggerPrompt ?? ""
  }

  var draftRequiresDaemonHeartbeat: Bool {
    let capabilities = draftBackend.capabilities
    return capabilities.supportsDaemonRecurrence && !capabilities.supportsInSessionRecurrence
  }

  var effectiveDraftUsesHeartbeat: Bool {
    draftUsesHeartbeat || draftRequiresDaemonHeartbeat
  }

  /// The form's interval as the seconds `LoopNode.heartbeatIntervalSeconds` stores.
  /// A custom value nobody can parse falls back to an hour, the same forgiveness
  /// `IntervalChoice.directiveValue` shows a blank one — the /loop path hands garbage
  /// to an agent that can interpret it, but a timer needs a number.
  var draftHeartbeatSeconds: Double {
    switch draftInterval {
    case .quarterHour: return 900
    case .hourly: return 3600
    case .sixHourly: return 21600
    case .daily: return 86400
    case .custom:
      return Self.seconds(fromInterval: draftCustomInterval) ?? 3600
    }
  }

  /// "90s", "30m", "2h", "3d" — bare digits count as minutes, matching what people
  /// type into the /loop field today.
  static func seconds(fromInterval text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return nil }
    let digits =
      trimmed.hasSuffix("s") || trimmed.hasSuffix("m") || trimmed.hasSuffix("h")
        || trimmed.hasSuffix("d") ? String(trimmed.dropLast()) : trimmed
    guard let value = Double(digits), value.isFinite, value > 0 else { return nil }
    switch trimmed.last {
    case "s": return value
    case "h": return value * 3600
    case "d": return value * 86400
    default: return value * 60
    }
  }

  /// What the promotion form currently means — nil while its one required field is
  /// empty. Computed like `draft`, so there is exactly one definition of it.
  ///
  /// A timed promotion asks only for the cadence; the work it repeats is what the
  /// session is already doing, seeded by the sketch's own note when there is one.
  var promotion: SketchPromotion? {
    switch promotionTarget {
    case .goalBased:
      let summary = promotionGoal.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !summary.isEmpty else { return nil }
      return .goal(GoalSpec(summary: summary))
    case .turnBased:
      return .turn(pausesBeforeWritesOnly: promotionPausesBeforeWritesOnly)
    case .timeBased:
      let note =
        nodePendingPromotion
        .flatMap { graph.nodes[id: $0]?.firstInstruction }?
        .trimmingCharacters(in: .whitespaces) ?? ""
      let task = note.isEmpty ? "Carry on with what this session has been doing." : note
      let cadence = promotionInterval.directiveValue(custom: promotionCustomInterval)
      return .timed(triggerPrompt: "/loop \(cadence) \(task)")
    case .sketch, .composite:
      return nil
    }
  }

  /// The composed `/loop` line the promotion form shows before it is written.
  var promotionTriggerPreview: String {
    guard promotionTarget == .timeBased, case .timed(let prompt)? = promotion else { return "" }
    return prompt
  }

  /// The `git worktree add` to run before creating the node, if the human asked for a
  /// new branch. The worktree lands next to the repository rather than inside it, so
  /// it never shows up as untracked content in the project the loops are working on.
  var newWorktreeRequest: ProjectFeature.WorktreeRequest? {
    guard case .newBranch = draftWorktree else { return nil }
    let branch = draftBranch.trimmingCharacters(in: .whitespaces)
    guard !branch.isEmpty else { return nil }
    let repositoryPath = graph.project.path
    let parent = (repositoryPath as NSString).deletingLastPathComponent
    let name = (repositoryPath as NSString).lastPathComponent
    let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
    return ProjectFeature.WorktreeRequest(
      repositoryPath: repositoryPath,
      worktreePath: (parent as NSString).appendingPathComponent("\(name)-\(safeBranch)"),
      branch: branch
    )
  }
}

/// The small types the form's derived values are expressed in, plus the edge editor's
/// draft types. Nested on `ProjectFeature` rather than `State` so views can name them
/// without going through the state type.
extension ProjectFeature {
  /// The picker's one row: the template plus which scope group it sits in.
  struct TemplatePickerRow: Equatable, Identifiable {
    let template: PromptTemplate
    let scope: TemplatePickerScope

    var id: UUID { template.id }
    /// "Goal" · "Timed · daily" · "Composite · 3 loops" · "Main" — the type in
    /// words, with the one qualifier that makes it specific.
    var typeLabel: String {
      switch template.shape {
      case .sketch, nil: return "Main"
      case .goalBased: return "Goal"
      case .timeBased:
        let cadence = template.settings?.cadence.map {
          $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        return cadence.map { "Timed · \($0)" } ?? "Timed"
      case .turnBased: return "Turn"
      case .composite:
        let count = template.settings?.carriedGraph?.nodes.count ?? 0
        return count > 0 ? "Composite · \(count) loops" : "Composite"
      }
    }
  }

  /// A field a template's `{token}`s can be sitting in, in form order — what `⇥`
  /// walks while any of them is still unfilled.
  enum TemplateTokenField: String, CaseIterable, Equatable, Sendable {
    case brief
    case doneCheck
    case metric
    case branch
  }

  /// The three groups, in the order the picker shows them: a project's committed
  /// templates first, always — the storage design's rule — then the briefs the app
  /// ships, then the ones this person saved. The last two are kept apart for good:
  /// scaffolding and somebody's own library are different things, and a list that
  /// mixed them once the library grew would make the shipped ones hard to find again.
  enum TemplatePickerScope: Equatable {
    case project
    case starter
    case home

    var displayName: String {
      switch self {
      case .project: return "This project"
      case .starter: return "Starters"
      case .home: return "Your templates"
      }
    }
  }

  /// What pressing **Test** on a done check found. No exit code: the shell session
  /// reports pass/fail and nothing finer, and a made-up number is the one detail
  /// somebody would act on.
  struct DoneCheckOutcome: Equatable {
    let passed: Bool
    let duration: TimeInterval

    var summary: String {
      "\(passed ? "passed" : "did not pass") · \(String(format: "%.1f", duration))s"
    }
  }

  /// How often a timed loop runs. The five the control offers, plus whatever someone
  /// types — GraphCode writes the directive either way.
  enum IntervalChoice: String, CaseIterable, Equatable {
    case quarterHour, hourly, sixHourly, daily, custom

    var displayName: String {
      switch self {
      case .quarterHour: return "15m"
      case .hourly: return "1h"
      case .sixHourly: return "6h"
      case .daily: return "Daily"
      case .custom: return "Custom…"
      }
    }

    func directiveValue(custom: String) -> String {
      switch self {
      case .quarterHour: return "15m"
      case .hourly: return "1h"
      case .sixHourly: return "6h"
      case .daily: return "24h"
      case .custom:
        let trimmed = custom.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "1h" : trimmed
      }
    }
  }

  /// A composite's intended cadence — see `State.composedTriggerPrompt`.
  enum CompositeSchedule: String, CaseIterable, Equatable {
    case daily, weekdays, weekly, onATrigger

    var displayName: String {
      switch self {
      case .daily: return "Daily"
      case .weekdays: return "Weekdays"
      case .weekly: return "Weekly"
      case .onATrigger: return "On a trigger"
      }
    }

    func summary(at time: String) -> String {
      self == .onATrigger ? "on a trigger" : "\(displayName.lowercased()) at \(time)"
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
    /// The plateau bound: stop re-firing when the source loop's metric hasn't improved
    /// across this many consecutive passes. Off by default — it only means something
    /// when the source loop carries a metric command, which the form can't know from
    /// here, so the control says so instead of hiding.
    var stopsOnPlateau = false
    var plateauPasses = 2

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
    /// command or plateau bound is set. Two independent bounds is the conservative
    /// reading of docs/08 — a predicate that never comes true (or a metric that never
    /// exists) shouldn't mean an unbounded loop.
    var cycleGuard: CycleGuard {
      CycleGuard(
        maxIterations: max(1, maxIterations),
        until: untilCommand.trimmingCharacters(in: .whitespaces).isEmpty ? nil : untilCommand,
        stopAfterPassesWithoutImprovement: stopsOnPlateau ? max(1, plateauPasses) : nil)
    }
  }

  /// The `git worktree add` a node's creation should run first.
  struct WorktreeRequest: Equatable {
    let repositoryPath: String
    let worktreePath: String
    let branch: String
  }

  /// What the node form's worktree picker is on. Most loops don't want one, so `.none`
  /// stays the default — docs/06-ux-terminals.md calls the binding optional, and a
  /// research or review loop has nothing to isolate.
  enum WorktreeSelection: Equatable, Hashable {
    case none
    case existing(WorktreeRef)
    case newBranch
  }
}
