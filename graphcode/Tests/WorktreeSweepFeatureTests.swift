import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The sweeper's selection rules: the safe tier arrives selected, the look tier never
/// does, the in-use tier can't be selected at all — and a removal re-reads git rather
/// than trusting its own bookkeeping.
@Suite
struct WorktreeSweepFeatureTests {
  private func inspection(
    branch: String, dirty: Int = 0, size: Int64? = 100
  ) -> WorktreeInspection {
    WorktreeInspection(
      ref: WorktreeRef(
        id: branch, repositoryPath: "/repo", worktreePath: "/repo-\(branch)",
        branch: branch),
      facts: WorktreeGitFacts(
        defaultBranch: "main", commitsNotLanded: 0, dirtyFileCount: dirty, pushed: true,
        sizeBytes: size))
  }

  @Test
  func sizesStreamInAfterTheRowsAppear() async {
    // The rows show in git-time; the disk walk fills sizes in behind them. This is
    // what keeps a 38-worktree backlog from spinning the sheet for half an hour.
    let unsized = inspection(branch: "landed", size: nil)
    let store = TestStore(
      initialState: WorktreeSweepFeature.State(
        projectPath: "/repo", projectName: "repo", nodes: [])
    ) {
      WorktreeSweepFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [unsized] }
      $0.gitClient.worktreeSizeBytes = { _ in 412 * 1024 * 1024 }
    }

    await store.send(.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([unsized], nodes: [])
      $0.selection = [unsized.ref.worktreePath]
    }
    await store.receive(\.sizeLoaded) {
      $0.assessments?[0].facts.sizeBytes = 412 * 1024 * 1024
    }
  }

  @Test
  func loadingPreselectsOnlyTheSafeTier() async {
    let safe = inspection(branch: "landed")
    let dirty = inspection(branch: "wip", dirty: 2)
    let store = TestStore(
      initialState: WorktreeSweepFeature.State(
        projectPath: "/repo", projectName: "repo", nodes: [])
    ) {
      WorktreeSweepFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [safe, dirty] }
    }

    await store.send(.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([safe, dirty], nodes: [])
      $0.selection = [safe.ref.worktreePath]
    }
  }

  @Test
  func anInUseRowCannotBeSelected() async {
    let worktree = inspection(branch: "busy")
    let runner = LoopNode(
      title: "Monitoring", loopType: .goalBased, worktreeBinding: worktree.ref,
      state: .running)
    let store = TestStore(
      initialState: WorktreeSweepFeature.State(
        projectPath: "/repo", projectName: "repo", nodes: [runner])
    ) {
      WorktreeSweepFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [worktree] }
    }

    await store.send(.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([worktree], nodes: [runner])
    }
    // No state change expected — the row is in use, so toggling it does nothing.
    await store.send(.rowToggled(worktree.ref.worktreePath))
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
  func removeClosesTheSheetAndRemovesInTheBackground() async {
    // The sheet must not outlive the click — the removal is the app's effect now, so
    // it survives the sheet's state being cleared, and the stats refresh afterwards.
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
      $0.worktreeSweep = nil
    }
    await store.finish()

    // Only what was selected — the dirty worktree was never touched.
    #expect(removed.value == ["landed"])
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
      $0.worktreeSweep = nil
    }
    await store.finish()

    #expect(removed.value == ["spare"])
  }

  @Test
  @MainActor
  func theCanvasMenuOpensTheSweeperScopedToItsOwnFolder() async {
    // The project canvas holds no app store, so its menu routes through project-scoped
    // signal actions — this is the interception that turns them into the shared sheets.
    let graph = LoopGraph(scope: .project(ProjectRef(path: "/repo", name: "repo")))
    let store = TestStore(
      initialState: AppFeature.State(projects: [ProjectFeature.State(graph: graph)])
    ) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.projects(.element(id: "/repo", action: .worktreeSweepTapped)))
    await store.receive(\.worktrees)
    #expect(store.state.worktreeSweep?.projectPath == "/repo")

    let stats = WorktreeFolderStats(total: 3, reclaimable: 2, totalBytes: 100)
    await store.send(.worktrees(.statsLoaded(projectPath: "/repo", stats)))
    // Mirrored into the project's own state — the canvas menu's count reads it there.
    #expect(store.state.worktreeStats["/repo"] == stats)
    #expect(store.state.projects[id: "/repo"]?.worktreeStats == stats)
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
    // Confirming closes it; --force reaches exactly the row whose removal discards
    // files.
    await store.send(.worktrees(.sweep(.removeConfirmed))) {
      $0.worktreeSweep = nil
    }
    await store.finish()

    #expect(forced.value == ["wip": true, "landed": false])
  }

  @Test
  func togglingTheSafeGroupDeselectsAndReselects() async {
    let first = inspection(branch: "one")
    let second = inspection(branch: "two")
    let store = TestStore(
      initialState: WorktreeSweepFeature.State(
        projectPath: "/repo", projectName: "repo", nodes: [])
    ) {
      WorktreeSweepFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in [first, second] }
    }

    await store.send(.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([first, second], nodes: [])
      $0.selection = [first.ref.worktreePath, second.ref.worktreePath]
    }
    await store.send(.allSafeToggled) {
      $0.selection = []
    }
    await store.send(.allSafeToggled) {
      $0.selection = [first.ref.worktreePath, second.ref.worktreePath]
    }
  }
}
