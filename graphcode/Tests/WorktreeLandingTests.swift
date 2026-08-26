import Foundation
import GraphcodeKit
import Testing

/// "Has this branch already landed?" — the question the safe tier rests on, and the one
/// `git cherry` alone answers wrongly for a squash-merged PR of more than one commit.
///
/// The git runner is a script of expected commands, so each case fixes both the answer
/// *and* the sequence that produced it.
@Suite
struct WorktreeLandingTests {
  private actor Recorder {
    private let answers: [String: String]
    private(set) var calls: [String] = []

    init(_ answers: [String: String]) { self.answers = answers }

    func run(_ arguments: [String]) -> String? {
      let command = arguments.joined(separator: " ")
      calls.append(command)
      return answers[command]
    }
  }

  private func reading(
    tip: String = "refs/heads/feat", bases: [String] = ["main"], _ answers: [String: String]
  ) async -> (WorktreeLandedReading, [String]) {
    let recorder = Recorder(answers)
    let result = await WorktreeLanding.reading(tip: tip, bases: bases) { arguments in
      await recorder.run(arguments)
    }
    return (result, await recorder.calls)
  }

  @Test
  func aCherryCleanBranchNeedsNoSquashProbe() async {
    let (result, calls) = await reading(["cherry main refs/heads/feat": "- abc123"])

    #expect(result == WorktreeLandedReading(commitsNotLanded: 0, squashLanded: false))
    #expect(result.landed)
    #expect(calls == ["cherry main refs/heads/feat"])
  }

  @Test
  func aSquashMergedBranchLandsThroughTheProbe() async {
    // Three commits, one combined patch upstream: `cherry` sees three strangers, the
    // probe replays them as the one commit the merge actually made.
    let (result, calls) = await reading([
      "cherry main refs/heads/feat": "+ a\n+ b\n+ c",
      "merge-base main refs/heads/feat": "base0",
      "rev-parse refs/heads/feat": "tip0",
      "rev-parse refs/heads/feat^{tree}": "tree0",
      "commit-tree tree0 -p base0 -m graphcode-landed-probe": "probe0",
      "cherry main probe0": "- probe0",
    ])

    #expect(result.landed)
    #expect(result.squashLanded)
    #expect(result.commitsNotLanded == 3)
    #expect(calls.last == "cherry main probe0")
  }

  /// Also the shape of "squash-merged, then someone added another commit": the probe
  /// hashes the branch's *current* tree, so the extra work stops it matching.
  @Test
  func unmergedWorkStaysUnmerged() async {
    let (result, _) = await reading([
      "cherry main refs/heads/feat": "+ a",
      "merge-base main refs/heads/feat": "base0",
      "rev-parse refs/heads/feat": "tip0",
      "rev-parse refs/heads/feat^{tree}": "tree0",
      "commit-tree tree0 -p base0 -m graphcode-landed-probe": "probe0",
      "cherry main probe0": "+ probe0",
    ])

    #expect(!result.landed)
    #expect(result.commitsNotLanded == 1)
  }

  @Test
  func theCountOfUnlandedCommitsIsReportedAsMeasured() async {
    // The row says how much is at stake, so the number has to be the real one — a
    // clamped count read "1 commit not in main" on a branch with four.
    let (result, _) = await reading([
      "cherry main refs/heads/feat": "+ a\n+ b\n+ c\n+ d",
      "merge-base main refs/heads/feat": "base0",
      "rev-parse refs/heads/feat": "tip0",
      "rev-parse refs/heads/feat^{tree}": "tree0",
      "commit-tree tree0 -p base0 -m graphcode-landed-probe": "probe0",
      "cherry main probe0": "+ probe0",
    ])

    #expect(result.commitsNotLanded == 4)
    #expect(!result.landed)
  }

  @Test
  func theNearerOfTwoBasesIsTheOneReported() async {
    // Local `main` is behind, so it sees more outstanding than `origin/main` does.
    // Neither says landed; the honest number is the smaller one.
    let (result, _) = await reading(
      bases: ["main", "refs/remotes/origin/main"],
      [
        "cherry main refs/heads/feat": "+ a\n+ b\n+ c",
        "merge-base main refs/heads/feat": "base0",
        "rev-parse refs/heads/feat": "tip0",
        "rev-parse refs/heads/feat^{tree}": "tree0",
        "commit-tree tree0 -p base0 -m graphcode-landed-probe": "probe0",
        "cherry main probe0": "+ probe0",
        "cherry refs/remotes/origin/main refs/heads/feat": "+ c",
        "merge-base refs/remotes/origin/main refs/heads/feat": "base1",
        "commit-tree tree0 -p base1 -m graphcode-landed-probe": "probe1",
        "cherry refs/remotes/origin/main probe1": "+ probe1",
      ])

    #expect(result.commitsNotLanded == 1)
    #expect(!result.landed)
  }

  @Test
  func aStaleLocalDefaultBranchIsNotTheLastWord() async {
    // The PR merged on the forge an hour ago; nobody has fetched since. Local `main`
    // says unmerged, `origin/main` says merged, and merged is the truth.
    let (result, _) = await reading(
      bases: ["main", "refs/remotes/origin/main"],
      [
        "cherry main refs/heads/feat": "+ a",
        "merge-base main refs/heads/feat": "base0",
        "rev-parse refs/heads/feat": "tip0",
        "rev-parse refs/heads/feat^{tree}": "tree0",
        "commit-tree tree0 -p base0 -m graphcode-landed-probe": "probe0",
        "cherry main probe0": "+ probe0",
        "cherry refs/remotes/origin/main refs/heads/feat": "- a",
      ])

    #expect(result.landed)
  }

  @Test
  func anAncestorTipSkipsTheProbeEntirely() async {
    // merge-base == tip means the branch is already an ancestor; there is nothing to
    // squash, and `commit-tree` would only write a pointless object.
    let (result, calls) = await reading([
      "cherry main refs/heads/feat": "+ a",
      "merge-base main refs/heads/feat": "same",
      "rev-parse refs/heads/feat": "same",
    ])

    #expect(!result.landed)
    #expect(!calls.contains { $0.hasPrefix("commit-tree") })
  }

  @Test
  func aFailedReadCountsAsUnlanded() async {
    // Every read here fails toward the cautious answer: a git hiccup can only move a
    // worktree out of the safe tier, never into it.
    let (result, _) = await reading([:])

    #expect(!result.landed)
    #expect(result.commitsNotLanded == 1)
  }

  @Test
  func theRemoteDefaultIsMeasuredOnlyWhenItHasMovedAhead() {
    #expect(
      WorktreeLanding.bases(defaultBranch: "main", localTip: "a", remoteTip: "a") == ["main"])
    #expect(
      WorktreeLanding.bases(defaultBranch: "main", localTip: "a", remoteTip: "b")
        == ["main", "refs/remotes/origin/main"])
    // A repository with no remote at all still has a local default branch to answer for.
    #expect(WorktreeLanding.bases(defaultBranch: "main", localTip: "a", remoteTip: nil) == ["main"])
    #expect(
      WorktreeLanding.bases(defaultBranch: "main", localTip: nil, remoteTip: "b")
        == ["refs/remotes/origin/main"])
  }
}
