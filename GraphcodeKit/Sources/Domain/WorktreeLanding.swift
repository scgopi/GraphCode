import Foundation

/// What one worktree's branch has managed to get into the default branch.
public struct WorktreeLandedReading: Equatable, Sendable {
  /// Patches on the branch with no equivalent upstream, per `git cherry`.
  public var commitsNotLanded: Int
  /// The branch's whole diff is upstream as a single squashed commit.
  public var squashLanded: Bool

  public init(commitsNotLanded: Int, squashLanded: Bool) {
    self.commitsNotLanded = commitsNotLanded
    self.squashLanded = squashLanded
  }

  public var landed: Bool { commitsNotLanded == 0 || squashLanded }
}

/// Deciding whether a branch's work has already reached the default branch — the one
/// question the sweeper's whole safe tier rests on.
///
/// `git cherry` alone gets this wrong twice, and both ways round in daily use:
///
/// * **Squash merges of more than one commit.** `cherry` matches patch-ids commit by
///   commit; "Squash and merge" collapses N commits into one combined patch that
///   matches none of them, so a merged three-commit PR reads as three commits not
///   landed — forever. The squash probe below is the standard fix: replay the branch's
///   *whole* diff as one throwaway commit on the merge base and ask `cherry` about
///   that instead.
/// * **A stale local default branch.** A PR merged on the forge is not in local `main`
///   until someone fetches, and a checkout that has been running loops all day is
///   normally behind. Measuring against `origin/main` as well costs one `cherry` and
///   answers "is it merged" rather than "have I pulled it yet".
///
/// The runner is injected so the sequence is one implementation for both the local and
/// the SSH client, and testable without a repository.
public enum WorktreeLanding {
  public typealias Git = @Sendable (_ arguments: [String]) async -> String?

  /// The refs to measure against — the local default branch, and its remote-tracking
  /// counterpart when that exists and has moved somewhere else.
  public static func bases(
    defaultBranch: String, localTip: String?, remoteTip: String?
  ) -> [String] {
    let remote = "refs/remotes/origin/\(defaultBranch)"
    guard let remoteTip, !remoteTip.isEmpty else { return [defaultBranch] }
    guard let localTip, !localTip.isEmpty else { return [remote] }
    return localTip == remoteTip ? [defaultBranch] : [defaultBranch, remote]
  }

  public static func reading(
    tip: String, bases: [String], git: Git
  ) async -> WorktreeLandedReading {
    // Optional, not a seeded 1: seeding the accumulator with the failure value made
    // `min` clamp every real count down to it, so a four-commit branch reported "1
    // commit not in main". The fallback belongs to a read that failed, not to a read
    // that succeeded and returned four.
    var fewest: Int?
    for base in bases {
      let notLanded = notLandedCount(await git(["cherry", base, tip]))
      if notLanded == 0 { return WorktreeLandedReading(commitsNotLanded: 0, squashLanded: false) }
      if await isSquashLanded(tip: tip, base: base, git: git) {
        return WorktreeLandedReading(commitsNotLanded: notLanded, squashLanded: true)
      }
      fewest = min(fewest ?? notLanded, notLanded)
    }
    return WorktreeLandedReading(commitsNotLanded: fewest ?? 1, squashLanded: false)
  }

  /// A failed or missing `cherry` counts as one commit not landed: every read here
  /// fails toward the cautious answer, so a git hiccup can only move a worktree *out*
  /// of the safe tier.
  static func notLandedCount(_ cherryOutput: String?) -> Int {
    guard let cherryOutput else { return 1 }
    let plus = cherryOutput.split(separator: "\n").filter { $0.hasPrefix("+") }.count
    return plus
  }

  /// Squashes the branch into one throwaway commit on the merge base and asks `cherry`
  /// whether *that* patch is upstream. The commit is written to the object store but
  /// referenced by nothing, so it is ordinary gc fodder.
  private static func isSquashLanded(tip: String, base: String, git: Git) async -> Bool {
    guard let mergeBase = await trimmed(git(["merge-base", base, tip])),
      let tipCommit = await trimmed(git(["rev-parse", tip])),
      // An ancestor has nothing to squash; `cherry` already answered for it.
      mergeBase != tipCommit,
      let tree = await trimmed(git(["rev-parse", "\(tip)^{tree}"])),
      let probe = await trimmed(
        git(["commit-tree", tree, "-p", mergeBase, "-m", "graphcode-landed-probe"])),
      let verdict = await trimmed(git(["cherry", base, probe]))
    else { return false }
    return verdict.hasPrefix("-")
  }

  private static func trimmed(_ output: String?) -> String? {
    guard let value = output?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }
}
