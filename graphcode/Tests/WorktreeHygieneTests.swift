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
    notLanded: Int = 0, dirty: Int = 0, pushed: Bool = true, prunable: Bool = false,
    size: Int64? = 100
  ) -> WorktreeGitFacts {
    WorktreeGitFacts(
      defaultBranch: "main", commitsNotLanded: notLanded, dirtyFileCount: dirty,
      pushed: pushed, prunable: prunable, sizeBytes: size)
  }

  private func node(
    boundTo worktree: WorktreeRef?, state: LoopState, title: String = "Usage"
  ) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, worktreeBinding: worktree, state: state)
  }

  @Test
  func landedCleanPushedAndUnboundIsSafe() {
    let assessment = WorktreeAssessment(ref: ref(), facts: facts(), binding: .none)

    #expect(assessment.tier == .safeToRemove)
    #expect(assessment.summary == "landed in main · clean tree · no loop bound")
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
      WorktreeAssessment(ref: ref(), facts: facts(pushed: false), binding: .none).tier
        == .lookBeforeRemoving)
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
  func prunableIsAlwaysSafeAndSaysWhy() {
    // Admin file with no directory: nothing on disk to lose, even with a stopped loop
    // still pointing at the path it used to be.
    let assessment = WorktreeAssessment(
      ref: ref(), facts: facts(prunable: true, size: nil),
      binding: .stopped(loopTitle: "old"))

    #expect(assessment.tier == .safeToRemove)
    #expect(assessment.summary == "stale admin file · nothing on disk to lose")
  }

  @Test
  func theLookSummaryNamesWhatWouldBeLost() {
    let unmergedAndDirty = WorktreeAssessment(
      ref: ref(), facts: facts(notLanded: 4, dirty: 2), binding: .none)
    #expect(unmergedAndDirty.summary == "4 commits not in main · 2 files uncommitted")

    let onlyBound = WorktreeAssessment(
      ref: ref(), facts: facts(), binding: .stopped(loopTitle: "looper"))
    #expect(onlyBound.summary == "merged · but a stopped loop still points here")

    let unpushed = WorktreeAssessment(ref: ref(), facts: facts(pushed: false), binding: .none)
    #expect(unpushed.summary == "not pushed")
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
