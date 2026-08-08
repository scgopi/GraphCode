import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The worktree sweeper for one folder — the backlog fix, next to the policy that is the
/// real one (`WorktreeHygienePolicy`).
///
/// Always scoped to a single folder: every route in (lane chip, context menu, File menu)
/// opens it already knowing which project it is about, so there is no all-projects list
/// to re-filter. Groups by `WorktreeTier` — what removing would lose — never by age.
@Reducer
struct WorktreeSweepFeature {
  @ObservableState
  struct State: Equatable, Identifiable {
    let projectPath: String
    let projectName: String
    /// The graph's loops at the moment the sheet opened — what `unbound` is read from.
    let nodes: [LoopNode]
    /// `nil` while the first inspection runs; empty for a folder with no worktrees.
    var assessments: [WorktreeAssessment]?
    /// Selected worktree paths. The safe tier starts fully selected; the look tier is
    /// never preselected; the in-use tier is not selectable at all.
    var selection: Set<String> = []
    var isRemoving = false
    /// Up while the "this discards uncommitted files" confirmation is showing — the
    /// gate between selecting a dirty worktree and actually forcing it away.
    var isConfirmingRemoval = false
    var failure: String?

    var id: String { projectPath }

    var safe: [WorktreeAssessment] { tiered(.safeToRemove) }
    var look: [WorktreeAssessment] { tiered(.lookBeforeRemoving) }
    var inUse: [WorktreeAssessment] { tiered(.inUse) }

    var selected: [WorktreeAssessment] {
      (assessments ?? []).filter { $0.isRemovable && selection.contains($0.id) }
    }
    var selectedBytes: Int64 {
      selected.compactMap(\.facts.sizeBytes).reduce(0, +)
    }
    var totalBytes: Int64 {
      (assessments ?? []).compactMap(\.facts.sizeBytes).reduce(0, +)
    }

    private func tiered(_ tier: WorktreeTier) -> [WorktreeAssessment] {
      (assessments ?? []).filter { $0.tier == tier }
    }
  }

  enum Action {
    case task
    case assessmentsLoaded([WorktreeAssessment])
    /// One worktree's `du` finishing — sizes arrive row by row after the facts, so a
    /// big backlog shows its rows in git-time rather than disk-walk-time.
    case sizeLoaded(id: String, bytes: Int64?)
    case loadFailed(String)
    case rowToggled(String)
    case allSafeToggled
    case removeTapped
    /// The dirty-selection confirmation's two exits.
    case removeConfirmed
    case removeCancelled
    case removalFinished(failure: String?)
  }

  @Dependency(\.gitClient) var gitClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        let path = state.projectPath
        let nodes = state.nodes
        return .run { send in
          do {
            let inspections = try await gitClient.inspectWorktrees(path)
            await send(.assessmentsLoaded(Self.assessments(inspections, nodes: nodes)))
          } catch {
            await send(.loadFailed(String(describing: error)))
          }
        }

      case .assessmentsLoaded(let assessments):
        state.assessments = assessments
        // Preselect the safe tier only — and only on the first load, so a refresh after
        // a removal doesn't quietly re-tick boxes the human just made a decision about.
        if state.selection.isEmpty && !state.isRemoving {
          state.selection = Set(assessments.filter { $0.tier == .safeToRemove }.map(\.id))
        } else {
          state.selection.formIntersection(assessments.map(\.id))
        }
        state.isRemoving = false
        // The rows are on screen; now walk the disk. Bounded, so 38 worktrees is four
        // `du`s at a time rather than 38 — and a prunable entry has no directory to ask.
        let unsized = assessments.filter { $0.facts.sizeBytes == nil && !$0.facts.prunable }
        guard !unsized.isEmpty else { return .none }
        return .run { send in
          await withTaskGroup(of: Void.self) { group in
            var iterator = unsized.makeIterator()
            func submit() {
              guard let assessment = iterator.next() else { return }
              group.addTask {
                let bytes = await gitClient.worktreeSizeBytes(assessment.ref.worktreePath)
                await send(.sizeLoaded(id: assessment.id, bytes: bytes))
              }
            }
            for _ in 0..<4 { submit() }
            for await _ in group { submit() }
          }
        }

      case .sizeLoaded(let id, let bytes):
        guard var assessments = state.assessments,
          let index = assessments.firstIndex(where: { $0.id == id })
        else { return .none }
        assessments[index].facts.sizeBytes = bytes
        state.assessments = assessments
        return .none

      case .loadFailed(let message):
        state.assessments = state.assessments ?? []
        state.isRemoving = false
        state.failure = message
        return .none

      case .rowToggled(let id):
        guard let assessment = state.assessments?.first(where: { $0.id == id }),
          assessment.isRemovable
        else { return .none }
        if state.selection.contains(id) {
          state.selection.remove(id)
        } else {
          state.selection.insert(id)
        }
        return .none

      case .allSafeToggled:
        let safeIDs = state.safe.map(\.id)
        if safeIDs.allSatisfy({ state.selection.contains($0) }) {
          state.selection.subtract(safeIDs)
        } else {
          state.selection.formUnion(safeIDs)
        }
        return .none

      case .removeTapped:
        let doomed = state.selected
        guard !doomed.isEmpty, !state.isRemoving else { return .none }
        // Losing uncommitted files is the one cost a checkbox alone must not carry —
        // the confirmation names it before anything is forced.
        if doomed.contains(where: \.removalDiscardsFiles) {
          state.isConfirmingRemoval = true
          return .none
        }
        return removalEffect(&state)

      case .removeConfirmed:
        state.isConfirmingRemoval = false
        return removalEffect(&state)

      case .removeCancelled:
        state.isConfirmingRemoval = false
        return .none

      case .removalFinished(let failure):
        state.failure = failure
        state.selection = []
        // Re-read rather than locally pruning the list: git is the authority on what a
        // removal actually left behind.
        return .send(.task)
      }
    }
  }

  /// The removal itself, shared by the direct path and the confirmed one. `--force`
  /// only for rows whose removal discards files — and only ever after the confirmation.
  private func removalEffect(_ state: inout State) -> Effect<Action> {
    let doomed = state.selected
    guard !doomed.isEmpty, !state.isRemoving else { return .none }
    state.isRemoving = true
    state.failure = nil
    return .run { send in
      var failures: [String] = []
      for assessment in doomed {
        do {
          try await gitClient.removeWorktreeAndBranch(
            assessment.ref, assessment.facts.prunable, assessment.removalDiscardsFiles)
        } catch {
          // Git's own last word, not a dumped enum — "fatal: … contains modified
          // or untracked files" explains itself; the case name explains nothing.
          let reason: String
          if case GitClientError.commandFailed(_, _, let output) = error {
            reason = output.trimmingCharacters(in: .whitespacesAndNewlines)
          } else {
            reason = error.localizedDescription
          }
          failures.append("\(assessment.ref.branch): \(reason)")
        }
      }
      await send(
        .removalFinished(failure: failures.isEmpty ? nil : failures.joined(separator: "\n")))
    }
  }

  /// Joins one folder's git facts with what only graphcode knows — which loops still
  /// point at each worktree.
  static func assessments(
    _ inspections: [WorktreeInspection], nodes: [LoopNode]
  ) -> [WorktreeAssessment] {
    inspections.map { inspection in
      let owner = nodes.first {
        $0.worktreeBinding?.worktreePath == inspection.ref.worktreePath
      }
      return WorktreeAssessment(
        ref: inspection.ref,
        facts: inspection.facts,
        binding: WorktreeAssessment.binding(
          forWorktreePath: inspection.ref.worktreePath, in: nodes),
        loopTitle: owner?.title)
    }
  }
}
