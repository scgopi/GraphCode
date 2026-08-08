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
    /// Remove doesn't remove here: this scope only decides whether the discard
    /// confirmation must intervene. `AppWorktreesReducer` intercepts the same actions,
    /// closes the sheet, and runs the removal in the background — the sheet must not
    /// outlive the click, and a child effect would die with the sheet's state.
    case removeTapped
    /// The dirty-selection confirmation's two exits.
    case removeConfirmed
    case removeCancelled
  }

  @Dependency(\.gitClient) var gitClient
  @Dependency(\.remoteGitClient) var remoteGitClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        let path = state.projectPath
        let nodes = state.nodes
        return .run { [gitClient, remoteGitClient] send in
          do {
            let inspections: [WorktreeInspection]
            if let location = RemoteProjectLocation.parse(projectPath: path) {
              inspections = try await remoteGitClient.inspectWorktrees(location)
            } else {
              inspections = try await gitClient.inspectWorktrees(path)
            }
            await send(.assessmentsLoaded(Self.assessments(inspections, nodes: nodes)))
          } catch {
            await send(.loadFailed(String(describing: error)))
          }
        }

      case .assessmentsLoaded(let assessments):
        state.assessments = assessments
        // Preselect the safe tier only, on the first load — and only rows that can
        // actually be removed (a locked worktree can be safe and still refuse).
        if state.selection.isEmpty {
          state.selection = Set(
            assessments.filter { $0.tier == .safeToRemove && $0.isRemovable }.map(\.id))
        } else {
          state.selection.formIntersection(assessments.map(\.id))
        }
        // The rows are on screen; now walk the disk. Bounded, so 38 worktrees is four
        // `du`s at a time rather than 38 — and a prunable entry has no directory to ask.
        let unsized = assessments.filter { $0.facts.sizeBytes == nil && !$0.facts.prunable }
        let path = state.projectPath
        guard !unsized.isEmpty else { return .none }
        return .run { [gitClient, remoteGitClient] send in
          let location = RemoteProjectLocation.parse(projectPath: path)
          await withTaskGroup(of: Void.self) { group in
            var iterator = unsized.makeIterator()
            func submit() {
              guard let assessment = iterator.next() else { return }
              group.addTask {
                let bytes: Int64?
                if let location {
                  bytes = await remoteGitClient.worktreeSizeBytes(
                    location, assessment.ref.worktreePath)
                } else {
                  bytes = await gitClient.worktreeSizeBytes(assessment.ref.worktreePath)
                }
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
        // Losing uncommitted files is the one cost a click alone must not carry —
        // the confirmation names it before anything is forced. A clean selection
        // passes straight through to the parent's interception.
        if state.selected.contains(where: \.removalDiscardsFiles) {
          state.isConfirmingRemoval = true
        }
        return .none

      case .removeConfirmed, .removeCancelled:
        state.isConfirmingRemoval = false
        return .none

      }
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
