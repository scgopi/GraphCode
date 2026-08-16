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
          metricDirection: draftMetricDirection)
        : nil,
      backend: draftBackend,
      // Only an *existing* worktree can be bound here; a new one has to be created on
      // disk first, which is `.createNodeConfirmed`'s job.
      worktree: {
        if case .existing(let ref) = draftWorktree { return ref }
        return nil
      }())
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
  var triggerPreview: String { composedTriggerPrompt ?? "" }

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
