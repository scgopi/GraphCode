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
    branch: String, dirty: Int = 0, size: Int64 = 100
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

  @Test
  func removingReReadsGitRatherThanTrustingItself() async {
    let safe = inspection(branch: "landed")
    let dirty = inspection(branch: "wip", dirty: 2)
    let remaining = LockIsolated([safe, dirty])
    let removed = LockIsolated<[String]>([])
    let store = TestStore(
      initialState: WorktreeSweepFeature.State(
        projectPath: "/repo", projectName: "repo", nodes: [])
    ) {
      WorktreeSweepFeature()
    } withDependencies: {
      $0.gitClient.inspectWorktrees = { _ in remaining.value }
      $0.gitClient.removeWorktreeAndBranch = { ref, _ in
        removed.withValue { $0.append(ref.branch) }
        remaining.withValue { $0.removeAll { $0.ref.worktreePath == ref.worktreePath } }
      }
    }

    await store.send(.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([safe, dirty], nodes: [])
      $0.selection = [safe.ref.worktreePath]
    }

    await store.send(.removeTapped) {
      $0.isRemoving = true
    }
    await store.receive(\.removalFinished) {
      $0.selection = []
    }
    await store.receive(\.task)
    await store.receive(\.assessmentsLoaded) {
      $0.assessments = WorktreeSweepFeature.assessments([dirty], nodes: [])
      $0.isRemoving = false
    }

    // Only what was selected — the dirty worktree was never touched.
    #expect(removed.value == ["landed"])
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
