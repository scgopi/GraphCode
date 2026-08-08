import Foundation

/// What git can say about one worktree, read once and carried as plain values.
///
/// `commitsNotLanded` comes from `git cherry` against the default branch, so squash and
/// rebase merges count as landed. `git branch --merged` alone would call almost every
/// reclaimable worktree unmerged on a squash-merge repo — the safe group would come back
/// empty exactly where the feature is needed most.
public struct WorktreeGitFacts: Codable, Equatable, Sendable {
  /// The branch `commitsNotLanded` was measured against, for the row's summary line.
  public var defaultBranch: String
  /// Patches on this branch with no equivalent in the default branch.
  public var commitsNotLanded: Int
  /// Staged, unstaged **and untracked** files — untracked included, because that is
  /// where a half-finished experiment lives.
  public var dirtyFileCount: Int
  /// Nothing ahead of upstream. A branch with no upstream counts as unpushed, not safe.
  public var pushed: Bool
  /// Admin file with no directory. Zero risk **for the directory** — the branch is a
  /// separate question, which is why `commitsNotLanded` is measured for prunable
  /// entries too rather than assumed.
  public var prunable: Bool
  /// `git worktree lock` — git refuses removal even with `--force`.
  public var locked: Bool
  public var sizeBytes: Int64?

  public var landed: Bool { commitsNotLanded == 0 }
  public var clean: Bool { dirtyFileCount == 0 }

  public init(
    defaultBranch: String,
    commitsNotLanded: Int,
    dirtyFileCount: Int,
    pushed: Bool,
    prunable: Bool = false,
    locked: Bool = false,
    sizeBytes: Int64? = nil
  ) {
    self.defaultBranch = defaultBranch
    self.commitsNotLanded = commitsNotLanded
    self.dirtyFileCount = dirtyFileCount
    self.pushed = pushed
    self.prunable = prunable
    self.locked = locked
    self.sizeBytes = sizeBytes
  }
}

/// Whether any loop — running or stopped — still points at a worktree.
///
/// This signal is the reason hygiene lives in graphcode and not in a shell alias: git
/// cannot know that a stopped loop's `worktreeBinding` still names this directory.
public enum WorktreeLoopBinding: Equatable, Sendable {
  case none
  case stopped(loopTitle: String)
  case running(loopTitle: String)

  public var isRunning: Bool {
    if case .running = self { return true }
    return false
  }
}

/// The three groups of the sweeper, ordered by what removing the worktree would lose.
public enum WorktreeTier: Equatable, Sendable {
  /// Landed, clean, pushed and unbound — or a stale admin file with no directory.
  /// Preselected; the only tier automatic removal may ever touch.
  case safeToRemove
  /// Unmerged commits, uncommitted files, unpushed work, or a stopped loop still bound.
  /// Never preselected: a human looks first.
  case lookBeforeRemoving
  /// A loop is running in it. Not selectable at all.
  case inUse
}

/// One worktree, classified. The classifier is pure so the tier logic — the part that
/// has to be right — is testable without a repository.
public struct WorktreeAssessment: Identifiable, Equatable, Sendable {
  public var ref: WorktreeRef
  public var facts: WorktreeGitFacts
  public var binding: WorktreeLoopBinding
  /// The last loop that used this worktree, for the row subtitle.
  public var loopTitle: String?
  public var resolvedAt: Date?

  public var id: String { ref.worktreePath }

  public init(
    ref: WorktreeRef,
    facts: WorktreeGitFacts,
    binding: WorktreeLoopBinding,
    loopTitle: String? = nil,
    resolvedAt: Date? = nil
  ) {
    self.ref = ref
    self.facts = facts
    self.binding = binding
    self.loopTitle = loopTitle
    self.resolvedAt = resolvedAt
  }

  public var tier: WorktreeTier {
    // A prunable entry with unlanded commits is not "nothing to lose" — the directory
    // is gone but removing it deletes the branch, and the branch is all that's left.
    if facts.prunable {
      return facts.landed ? .safeToRemove : .lookBeforeRemoving
    }
    if binding.isRunning { return .inUse }
    // Locked means a human action stands between here and removal (`git worktree
    // unlock`) — that is "look before removing" by definition, however clean it is.
    if facts.locked { return .lookBeforeRemoving }
    if facts.landed && facts.clean && facts.pushed, case .none = binding {
      return .safeToRemove
    }
    return .lookBeforeRemoving
  }

  /// Whether the sweeper can act on this row at all. A running loop locks its
  /// worktree, and so does `git worktree lock` — git refuses a locked removal even
  /// with `--force`, so offering the checkbox would be offering a silent failure.
  /// Everything else is the human's to remove, including a dirty tree, which asks for
  /// confirmation first.
  public var isRemovable: Bool { !binding.isRunning && !facts.locked }

  /// Whether removing this worktree discards files nothing else has a copy of — the
  /// case the sweeper confirms before forcing.
  public var removalDiscardsFiles: Bool { !facts.prunable && !facts.clean }

  /// The mono summary line under the branch name — what you'd lose, in its own words.
  public var summary: String {
    if facts.prunable {
      guard !facts.landed else { return "stale admin file · nothing on disk to lose" }
      let unit = facts.commitsNotLanded == 1 ? "commit" : "commits"
      return "directory gone · \(facts.commitsNotLanded) \(unit) not in "
        + "\(facts.defaultBranch) — only the branch remains"
    }
    if binding.isRunning { return "a loop is running in it" }
    if tier == .safeToRemove {
      return "landed in \(facts.defaultBranch) · clean tree · no loop bound"
    }
    var reasons: [String] = []
    if facts.commitsNotLanded > 0 {
      let unit = facts.commitsNotLanded == 1 ? "commit" : "commits"
      reasons.append("\(facts.commitsNotLanded) \(unit) not in \(facts.defaultBranch)")
    }
    if facts.dirtyFileCount > 0 {
      let unit = facts.dirtyFileCount == 1 ? "file" : "files"
      reasons.append("\(facts.dirtyFileCount) \(unit) uncommitted")
    }
    if !facts.pushed { reasons.append("not pushed") }
    if facts.locked { reasons.append("locked") }
    if case .stopped = binding {
      reasons =
        reasons.isEmpty
        ? ["merged · but a stopped loop still points here"]
        : reasons + ["a stopped loop still points here"]
    }
    return reasons.joined(separator: " · ")
  }
}

extension WorktreeAssessment {
  /// Derives the binding for one worktree from the loops of its project's graph. Matched
  /// on the worktree path — the one fact `WorktreeRef` and a loop's binding share.
  public static func binding(
    forWorktreePath worktreePath: String, in nodes: [LoopNode]
  ) -> WorktreeLoopBinding {
    let bound = nodes.filter { $0.worktreeBinding?.worktreePath == worktreePath }
    if let running = bound.first(where: { !$0.isResolved }) {
      return .running(loopTitle: running.title)
    }
    if let stopped = bound.first {
      return .stopped(loopTitle: stopped.title)
    }
    return .none
  }
}

/// The per-folder policy — the real fix. A user who sets "Remove it" once never sees
/// the sweeper again; the sweeper is only the backlog fix.
public struct WorktreeHygienePolicy: Codable, Equatable, Sendable {
  /// What happens when a loop resolves and its branch has landed. Automatic removal
  /// only ever touches the safe tier; anything else waits for a human regardless.
  public enum ResolveAction: String, Codable, CaseIterable, Sendable {
    case remove
    case ask
    case keep

    public var displayName: String {
      switch self {
      case .remove: return "Remove it"
      case .ask: return "Ask me"
      case .keep: return "Keep it"
      }
    }
  }

  public var onResolveLanded: ResolveAction
  /// The lane chip turns amber past either threshold. A repo with four worktrees is
  /// working as designed; the chip appears when the folder is genuinely accumulating.
  public var noticeSizeBytes: Int64
  public var noticeCount: Int

  public init(
    onResolveLanded: ResolveAction = .ask,
    noticeSizeBytes: Int64 = 2 << 30,
    noticeCount: Int = 8
  ) {
    self.onResolveLanded = onResolveLanded
    self.noticeSizeBytes = noticeSizeBytes
    self.noticeCount = noticeCount
  }

  /// A missing key takes its default, same bargain as `GraphcodeSettings`.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    onResolveLanded =
      try container.decodeIfPresent(ResolveAction.self, forKey: .onResolveLanded) ?? .ask
    noticeSizeBytes =
      try container.decodeIfPresent(Int64.self, forKey: .noticeSizeBytes) ?? 2 << 30
    noticeCount = try container.decodeIfPresent(Int.self, forKey: .noticeCount) ?? 8
  }
}
