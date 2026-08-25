import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Removing a worktree: the removal is the app's effect, not the sheet's, it re-reads
/// git rather than trusting a minutes-old row, and — the part that used to be missing —
/// it says so when it could not go through.
@Suite
struct WorktreeRemovalTests {
  private func inspection(
    branch: String, dirty: Int = 0, size: Int64? = 100, locked: Bool = false
  ) -> WorktreeInspection {
    WorktreeInspection(
      ref: WorktreeRef(
        id: branch, repositoryPath: "/repo", worktreePath: "/repo-\(branch)",
        branch: branch),
      facts: WorktreeGitFacts(
        defaultBranch: "main", commitsNotLanded: 0, dirtyFileCount: dirty, pushed: true,
        locked: locked, sizeBytes: size))
  }

  /// The state a sheet mid-use would hold, for the app-level removal tests.
  private func openSweep(
    _ inspections: [WorktreeInspection], selecting: [String]
  ) -> WorktreeSweepFeature.State {
    var sweep = WorktreeSweepFeature.State(
      projectPath: "/repo", projectName: "repo", nodes: [])
    sweep.assessments = WorktreeSweepFeature.assessments(inspections, nodes: [])
    sweep.selection = Set(selecting)
    return sweep
  }

  @Test
  @MainActor
  func removeRunsInTheAppAndClosesTheSheetOnceItHasAnswered() async {
    // The removal is the app's effect, not the sheet's — it has to outlive the click.
    // The sheet closes when every removal has answered, and not before: a refusal has
    // nowhere else to be reported.
    let safe = inspection(branch: "landed")
    let dirty = inspection(branch: "wip", dirty: 2)
    let removed = LockIsolated<[String]>([])
    var initial = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/repo", name: "repo"))))
    ])
    initial.worktreeSweep = openSweep([safe, dirty], selecting: [safe.ref.worktreePath])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [safe, dirty] }
      $0.gitClient.worktreeSizeBytes = { _ in nil }
      $0.gitClient.removeWorktreeAndBranch = { ref, _, _ in
        removed.withValue { $0.append(ref.branch) }
      }
    }
    store.exhaustivity = .off

    await store.send(.worktrees(.sweep(.removeTapped))) {
      $0.worktreeSweep?.isRemoving = true
    }
    await store.receive(\.worktrees.removalsFinished)

    // Only what was selected — the dirty worktree was never touched.
    #expect(removed.value == ["landed"])
    #expect(store.state.worktreeSweep == nil)
    await store.finish()
  }

  @Test
  @MainActor
  func aWorktreeClaimedByALoopAfterSelectionIsNotRemoved() async {
    // The sheet's assessment can be minutes old. Removal re-checks the live graphs:
    // a loop that started in the worktree after selection keeps it alive, whatever
    // the row claimed when it was ticked.
    let claimed = inspection(branch: "landed")
    let free = inspection(branch: "spare")
    let removed = LockIsolated<[String]>([])
    let runner = LoopNode(
      title: "Started late", loopType: .goalBased, worktreeBinding: claimed.ref,
      state: .running)
    var initial = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(
          scope: .project(ProjectRef(path: "/repo", name: "repo")), nodes: [runner]))
    ])
    initial.worktreeSweep = openSweep(
      [claimed, free], selecting: [claimed.ref.worktreePath, free.ref.worktreePath])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [claimed, free] }
      $0.gitClient.worktreeSizeBytes = { _ in nil }
      $0.gitClient.removeWorktreeAndBranch = { ref, _, _ in
        removed.withValue { $0.append(ref.branch) }
      }
    }
    store.exhaustivity = .off

    await store.send(.worktrees(.sweep(.removeTapped))) {
      $0.worktreeSweep?.isRemoving = true
    }
    await store.receive(\.worktrees.removalsFinished)

    #expect(removed.value == ["spare"])
    // Dropping it silently is what made a click look like it did nothing: the sheet
    // stays up and names the worktree it could not take.
    #expect(store.state.worktreeSweep?.failure?.contains("landed") == true)
    await store.finish()
  }

  @Test
  @MainActor
  func aRemovalGitRefusesLeavesTheSheetUpWithGitsReason() async {
    // The bug this closes: `try?` swallowed every refusal, the sheet closed, the row
    // came back on reopen, and nothing anywhere said why.
    let stuck = inspection(branch: "landed")
    var initial = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/repo", name: "repo"))))
    ])
    initial.worktreeSweep = openSweep([stuck], selecting: [stuck.ref.worktreePath])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [stuck] }
      $0.gitClient.worktreeSizeBytes = { _ in nil }
      $0.gitClient.removeWorktreeAndBranch = { _, _, _ in
        throw GitClientError.commandFailed(
          command: "git worktree remove", status: 128,
          output: "fatal: validation failed, cannot remove working tree\nhint: retry")
      }
    }
    store.exhaustivity = .off

    await store.send(.worktrees(.sweep(.removeTapped)))
    await store.receive(\.worktrees.removalsFinished)

    #expect(store.state.worktreeSweep != nil)
    #expect(store.state.worktreeSweep?.isRemoving == false)
    #expect(
      store.state.worktreeSweep?.failure
        == "landed: validation failed, cannot remove working tree")
    await store.finish()
  }

  @Test
  @MainActor
  func aWorktreeThatTurnedDirtyAfterSelectionIsRefusedOutLoud() async {
    // Consent is the human's, measured freshness is git's. A clean row that grew
    // uncommitted files since the list was built would fail an unforced removal
    // without a word, so it is never attempted.
    let listed = inspection(branch: "landed")
    let nowDirty = inspection(branch: "landed", dirty: 3)
    let removed = LockIsolated<[String]>([])
    var initial = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/repo", name: "repo"))))
    ])
    initial.worktreeSweep = openSweep([listed], selecting: [listed.ref.worktreePath])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [nowDirty] }
      $0.gitClient.worktreeSizeBytes = { _ in nil }
      $0.gitClient.removeWorktreeAndBranch = { ref, _, _ in
        removed.withValue { $0.append(ref.branch) }
      }
    }
    store.exhaustivity = .off

    await store.send(.worktrees(.sweep(.removeTapped)))
    await store.receive(\.worktrees.removalsFinished)

    #expect(removed.value.isEmpty)
    #expect(store.state.worktreeSweep?.failure?.contains("uncommitted files appeared") == true)
    await store.finish()
  }

  @Test
  @MainActor
  func aDirtySelectionConfirmsThenForcesInTheBackground() async {
    let dirty = inspection(branch: "wip", dirty: 2)
    let clean = inspection(branch: "landed")
    let forced = LockIsolated<[String: Bool]>([:])
    var initial = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/repo", name: "repo"))))
    ])
    initial.worktreeSweep = openSweep(
      [dirty, clean], selecting: [dirty.ref.worktreePath, clean.ref.worktreePath])
    let store = TestStore(initialState: initial) {
      AppFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [dirty, clean] }
      $0.gitClient.worktreeSizeBytes = { _ in nil }
      $0.gitClient.removeWorktreeAndBranch = { ref, _, force in
        forced.withValue { $0[ref.branch] = force }
      }
    }
    store.exhaustivity = .off

    // The dirty selection raises the confirmation and the sheet stays up.
    await store.send(.worktrees(.sweep(.removeTapped))) {
      $0.worktreeSweep?.isConfirmingRemoval = true
    }
    // Confirming starts the removal; --force reaches exactly the row whose removal
    // discards files.
    await store.send(.worktrees(.sweep(.removeConfirmed))) {
      $0.worktreeSweep?.isConfirmingRemoval = false
      $0.worktreeSweep?.isRemoving = true
    }
    await store.receive(\.worktrees.removalsFinished)

    #expect(forced.value == ["wip": true, "landed": false])
    #expect(store.state.worktreeSweep == nil)
    await store.finish()
  }
}
