import ComposableArchitecture
import Foundation
import GraphcodeKit

/// `ProjectFeature.State`'s derived values — what the form currently means, which loops
/// want a human, and the worktree the form is about to create. Split out of
/// `ProjectFeature` purely for size; they're all pure functions of the state's stored
/// fields, deliberately computed rather than cached so nothing can disagree with the
/// graph the daemon broadcast.
extension ProjectFeature.State {
  /// Which of this project's loops want a human, by node id — the same rollup the
  /// sidebar's monitor shows, scoped to this graph so the canvas can mark them
  /// (docs/06-ux-terminals.md#graph-canvas) without a second opinion about what
  /// "needs attention" means.
  var attentionReasons: [UUID: AttentionReason] {
    Dictionary(
      uniqueKeysWithValues: AttentionRollup.fullRollup(across: [graph])
        .map { ($0.nodeID, $0.reason) })
  }

  /// The form's fields as the value actually sent. Built on demand rather than kept
  /// alongside the fields, so there's exactly one definition of what the form means.
  var draft: NodeDraft {
    NodeDraft(
      id: draftID,
      title: draftTitle,
      loopType: draftLoopType,
      checkDescription: draftLoopType == .turnBased ? draftCheck : nil,
      triggerPrompt: draftLoopType == .timeBased ? draftPrompt : nil,
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
