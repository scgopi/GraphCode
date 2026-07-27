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
      title: draftTitle,
      loopType: draftLoopType,
      checkDescription: draftLoopType == .turnBased ? draftCheck : nil,
      triggerPrompt: draftLoopType == .timeBased ? draftPrompt : nil,
      goal: draftLoopType == .goalBased
        ? GoalSpec(
          summary: draftGoal, predicate: draftPredicate.isEmpty ? nil : draftPredicate)
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

/// The two small types the form's derived values are expressed in. Nested on
/// `ProjectFeature` rather than `State` so views can name them without going through
/// the state type.
extension ProjectFeature {
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
