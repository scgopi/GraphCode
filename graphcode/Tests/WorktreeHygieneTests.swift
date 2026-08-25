import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The worktree classifier — the part of hygiene that has to be right. A worktree
/// wrongly called safe is someone's unpushed work deleted; one wrongly called unsafe
/// just makes the safe group smaller. Every rule here leans the second way.
@Suite
struct WorktreeHygieneTests {
  private func ref(_ branch: String = "fix-thing") -> WorktreeRef {
    WorktreeRef(
      id: branch, repositoryPath: "/repo", worktreePath: "/repo-\(branch)", branch: branch)
  }

  private func facts(
    notLanded: Int = 0, squashLanded: Bool = false, dirty: Int = 0, pushed: Bool = true,
    prunable: Bool = false, locked: Bool = false, size: Int64? = 100
  ) -> WorktreeGitFacts {
    WorktreeGitFacts(
      defaultBranch: "main", commitsNotLanded: notLanded, squashLanded: squashLanded,
      dirtyFileCount: dirty, pushed: pushed, prunable: prunable, locked: locked,
      sizeBytes: size)
  }

  private func node(
    boundTo worktree: WorktreeRef?, state: LoopState, title: String = "Usage"
  ) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, worktreeBinding: worktree, state: state)
  }

  @Test
  func landedCleanAndUnboundIsSafe() {
    let assessment = WorktreeAssessment(ref: ref(), facts: facts(), binding: .none)

    #expect(assessment.tier == .safeToRemove)
    #expect(assessment.summary == "merged into main · clean tree · no loop bound")
  }

  @Test
  func aSquashMergedBranchIsSafeAndSaysSo() {
    // `git cherry` counts every commit of a squash-merged PR as unlanded — the whole
    // branch arrived upstream as one combined patch that matches none of them.
    let assessment = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 3, squashLanded: true), binding: .none)

    #expect(assessment.facts.landed)
    #expect(assessment.tier == .safeToRemove)
    #expect(assessment.summary == "squash-merged into main · clean tree · no loop bound")
  }

  @Test
  func aMergedBranchWhoseRemoteIsGoneIsStillSafe() {
    // The forge deletes the branch on merge, so `@{upstream}` has read "gone" — and
    // unpushed — ever since. Nothing is lost by removing it: every commit has an
    // equivalent in main.
    let assessment = WorktreeAssessment(ref: ref(), facts: facts(pushed: false), binding: .none)

    #expect(assessment.tier == .safeToRemove)
    #expect(!assessment.summary.contains("not pushed"))
  }

  @Test
  func aMergedWorktreeSaysMergedEvenWhenSomethingElseIsWrong() {
    // The complaint this answers: a merged PR whose directory has build residue read
    // as "1 file uncommitted" and never mentioned the merge at all.
    let dirty = WorktreeAssessment(ref: ref(), facts: facts(dirty: 1), binding: .none)

    #expect(dirty.tier == .lookBeforeRemoving)
    #expect(dirty.summary == "merged into main · 1 file uncommitted")
  }

  @Test
  func eachMissingSignalDropsToLookBeforeRemoving() {
    // One at a time, because the trap is a classifier that only checks some of them.
    #expect(
      WorktreeAssessment(ref: ref(), facts: facts(notLanded: 4), binding: .none).tier
        == .lookBeforeRemoving)
    #expect(
      WorktreeAssessment(ref: ref(), facts: facts(dirty: 2), binding: .none).tier
        == .lookBeforeRemoving)
    #expect(
      WorktreeAssessment(ref: ref(), facts: facts(notLanded: 1, pushed: false), binding: .none)
        .tier == .lookBeforeRemoving)
    #expect(
      WorktreeAssessment(
        ref: ref(), facts: facts(), binding: .stopped(loopTitle: "looper")
      ).tier == .lookBeforeRemoving)
  }

  @Test
  func aRunningLoopMakesItInUseWhateverGitSays() {
    let assessment = WorktreeAssessment(
      ref: ref(), facts: facts(), binding: .running(loopTitle: "Monitoring"))

    #expect(assessment.tier == .inUse)
    #expect(assessment.summary == "a loop is running in it")
  }

  @Test
  func prunableIsSafeOnlyWhenItsBranchHasLanded() {
    // Admin file with no directory: nothing on disk to lose, even with a stopped loop
    // still pointing at the path it used to be.
    let landed = WorktreeAssessment(
      ref: ref(), facts: facts(prunable: true, size: nil),
      binding: .stopped(loopTitle: "old"))
    #expect(landed.tier == .safeToRemove)
    #expect(landed.summary == "stale admin file · nothing on disk to lose")

    // But a pruned registration whose branch holds unlanded commits is exactly the
    // case where "nothing to lose" would delete the only ref those commits have.
    let unlanded = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 3, prunable: true, size: nil), binding: .none)
    #expect(unlanded.tier == .lookBeforeRemoving)
    #expect(
      unlanded.summary == "directory gone · 3 commits not in main — only the branch remains")
  }

  @Test
  func aLockedWorktreeIsNotRemovable() {
    // git refuses a locked removal even with --force; a checkbox would offer a
    // silent failure.
    let locked = WorktreeAssessment(
      ref: ref(), facts: facts(locked: true), binding: .none)
    #expect(!locked.isRemovable)
    // However clean, a lock needs a human first — never the preselected tier.
    #expect(locked.tier == .lookBeforeRemoving)
    #expect(locked.summary.contains("locked"))
  }

  @Test
  func theLookSummaryNamesWhatWouldBeLost() {
    let unmergedAndDirty = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 4, dirty: 2), binding: .none)
    #expect(unmergedAndDirty.summary == "4 commits not in main · 2 files uncommitted")

    let onlyBound = WorktreeAssessment(
      ref: ref(), facts: facts(), binding: .stopped(loopTitle: "looper"))
    #expect(onlyBound.summary == "merged into main · a stopped loop still points here")

    let unpushed = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 1, pushed: false), binding: .none)
    #expect(unpushed.summary == "1 commit not in main · not pushed")
  }

  @Test
  func bindingComesFromLoopsRunningOrStopped() {
    let worktree = ref()
    let running = node(boundTo: worktree, state: .running)
    let stopped = node(boundTo: worktree, state: .stopped, title: "old")
    let unrelated = node(boundTo: ref("other"), state: .running)

    // A running loop outranks a stopped one pointing at the same path.
    #expect(
      WorktreeAssessment.binding(
        forWorktreePath: worktree.worktreePath, in: [stopped, running, unrelated])
        == .running(loopTitle: "Usage"))
    #expect(
      WorktreeAssessment.binding(forWorktreePath: worktree.worktreePath, in: [stopped])
        == .stopped(loopTitle: "old"))
    #expect(
      WorktreeAssessment.binding(forWorktreePath: worktree.worktreePath, in: [unrelated])
        == WorktreeLoopBinding.none)
  }

  @Test
  func aResolvedLoopStillCountsAsStopped() {
    // The whole reason this lives in graphcode: git cannot know a succeeded loop's
    // binding still names this directory.
    let worktree = ref()
    let done = node(boundTo: worktree, state: .succeeded)

    #expect(
      WorktreeAssessment.binding(forWorktreePath: worktree.worktreePath, in: [done])
        == .stopped(loopTitle: "Usage"))
  }

  @Test
  func onlyARunningLoopLocksItsWorktree() {
    // Anything not in use is the human's to remove — a dirty tree included, which is
    // the one whose removal discards files and therefore confirms first.
    let dirty = WorktreeAssessment(ref: ref(), facts: facts(dirty: 2), binding: .none)
    #expect(dirty.isRemovable)
    #expect(dirty.removalDiscardsFiles)

    let unmergedButClean = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 3), binding: .none)
    #expect(unmergedButClean.isRemovable)
    #expect(!unmergedButClean.removalDiscardsFiles)

    let running = WorktreeAssessment(
      ref: ref(), facts: facts(), binding: .running(loopTitle: "busy"))
    #expect(!running.isRemovable)

    let prunable = WorktreeAssessment(
      ref: ref(), facts: facts(prunable: true, size: nil), binding: .none)
    #expect(prunable.isRemovable)
    #expect(!prunable.removalDiscardsFiles)
  }

  @Test
  func aReclaimOfferTurnsTheCardIntoTheResolveMoment() {
    let offer = WorktreeAssessment(
      ref: ref(), facts: facts(size: 312 * 1024 * 1024), binding: .none)
    let done = node(boundTo: ref(), state: .succeeded)

    let card = LoopCardPresentation(node: done, reclaimOffer: offer)

    #expect(card.detail == .reclaim)
    #expect(card.liveLine?.hasPrefix("landed in main") == true)
    #expect(card.liveLine?.hasSuffix("left behind") == true)
  }

  @Test
  func anOfferOnAnUnresolvedLoopIsIgnored() {
    // The graph moved between the assessment and the render — a restarted loop's card
    // must not offer to delete the worktree it is working in.
    let offer = WorktreeAssessment(ref: ref(), facts: facts(), binding: .none)
    let running = node(boundTo: ref(), state: .running)

    #expect(LoopCardPresentation(node: running, reclaimOffer: offer).detail != .reclaim)
  }

  @Test
  func theTitlebarNoticeAppearsOnlyPastAFoldersOwnThreshold() {
    var state = AppFeature.State(projects: [
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/calm", name: "calm")))),
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/busy", name: "busy")))),
      ProjectFeature.State(
        graph: LoopGraph(scope: .project(ProjectRef(path: "/heavy", name: "heavy")))),
    ])
    // Four worktrees is a repo working as designed; eight is accumulating; a folder
    // over its byte threshold counts even with few worktrees.
    state.worktreeStats["/calm"] = WorktreeFolderStats(
      total: 4, reclaimable: 2, totalBytes: 500)
    state.worktreeStats["/busy"] = WorktreeFolderStats(
      total: 8, reclaimable: 5, totalBytes: 1000)
    state.worktreeStats["/heavy"] = WorktreeFolderStats(
      total: 2, reclaimable: 0, totalBytes: 5000)

    let notices = state.worktreeNotices { _ in
      WorktreeHygienePolicy(noticeSizeBytes: 4000, noticeCount: 8)
    }

    // Worst accumulation first — the chip names the first and counts the rest.
    #expect(notices.map(\.folderName) == ["heavy", "busy"])
  }

  @Test
  func policyDecodesFromAnEmptyObjectWithDefaults() throws {
    let policy = try JSONDecoder().decode(
      WorktreeHygienePolicy.self, from: Data("{}".utf8))

    #expect(policy.onResolveLanded == .ask)
    #expect(policy.noticeSizeBytes == 2 << 30)
    #expect(policy.noticeCount == 8)
  }

  @Test
  func settingsWithoutPoliciesDecodeToEmptyAndAnswerTheDefault() throws {
    let settings = try JSONDecoder().decode(
      GraphcodeSettings.self, from: Data("{}".utf8))

    #expect(settings.worktreePolicies.isEmpty)
    #expect(settings.worktreePolicy(forProjectPath: "/anything").onResolveLanded == .ask)
  }

  @Test
  func settingsRoundTripKeepsAFolderPolicy() throws {
    var settings = GraphcodeSettings()
    settings.worktreePolicies["/repo"] = WorktreeHygienePolicy(
      onResolveLanded: .remove, noticeSizeBytes: 1 << 30, noticeCount: 4)

    let decoded = try JSONDecoder().decode(
      GraphcodeSettings.self, from: JSONEncoder().encode(settings))

    #expect(decoded.worktreePolicy(forProjectPath: "/repo").onResolveLanded == .remove)
    #expect(decoded.worktreePolicy(forProjectPath: "/repo").noticeCount == 4)
    #expect(decoded.worktreePolicy(forProjectPath: "/other").onResolveLanded == .ask)
  }
}
