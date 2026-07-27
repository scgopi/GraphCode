import Foundation
import GraphcodeKit
import Testing

/// `NodeDraft.isValid` is where docs/08-quality-and-token-budgets.md's "make the
/// cheap-to-ignore version structurally awkward" actually lives: no check means no
/// turn-based node, no stop condition means no goal-based node, and an impossible
/// backend/loop-type pairing is refused rather than silently degraded
/// (docs/04-cli-backends.md).
///
/// It's checked on the daemon side, so these are the rules for every client — the form's
/// disabled Create button is a courtesy on top, not the enforcement.
@Suite
struct NodeDraftTests {
  @Test
  func aTurnBasedDraftNeedsARealCheck() {
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?").isValid)
    #expect(!NodeDraft(title: "Research", loopType: .turnBased).isValid)
    #expect(
      !NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "   ").isValid)
  }

  @Test
  func aGoalBasedDraftNeedsAGoalButNotAPredicate() {
    // The predicate is optional on purpose: plenty of real goals have no honest shell
    // equivalent, and inventing one would be worse than admitting it.
    #expect(
      NodeDraft(title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"))
        .isValid)
    #expect(!NodeDraft(title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "")).isValid)
    #expect(!NodeDraft(title: "Ship", loopType: .goalBased).isValid)
  }

  @Test
  func aTimeBasedDraftNeedsAPrompt() {
    #expect(
      NodeDraft(title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check").isValid)
    #expect(!NodeDraft(title: "Poll", loopType: .timeBased).isValid)
  }

  @Test
  func anUntitledDraftIsNeverValid() {
    #expect(
      !NodeDraft(title: "  ", loopType: .turnBased, checkDescription: "Sound?").isValid)
  }

  @Test
  func aProactiveDraftNeedsOnlyATitleAndGetsAnEmptySubGraph() {
    // A composite is built by editing its sub-graph after creation, so demanding a
    // populated one up front would mean a modal that can't be filled in until the thing
    // it creates exists. The real gate is arming, not creating.
    let draft = NodeDraft(title: "Triage inbox", loopType: .proactive)
    #expect(draft.isValid)

    let node = draft.makeNode()
    #expect(node.subGraph != nil)
    #expect(node.subGraph?.nodes.isEmpty == true)
    // Created, not armed — nothing runs until it has been piloted.
    #expect(node.pilotState == .notPiloted)
    #expect(!node.pilotState.canArm)
  }

  @Test
  func onlyAProactiveNodeGetsASubGraph() {
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "?")
        .makeNode().subGraph == nil)
  }

  @Test
  func aBackendThatCannotHostTheLoopTypeIsRefused() {
    // Codex hasn't been spiked, so its capability row is all-false — it can host a
    // turn-based loop (which needs nothing but a session) and nothing else.
    #expect(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "Sound?", backend: .codex
      ).isValid)
    #expect(
      !NodeDraft(
        title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
        backend: .codex
      ).isValid)
  }

  @Test
  func onlyClaudeCodeIsMarkedSpiked() {
    // The other two rows are conservative placeholders, not findings. If this ever flips
    // it should be because someone actually ran the CLI (docs/07-roadmap.md#phase-5).
    #expect(CLISessionBackendKind.claudeCode.isSpiked)
    #expect(!CLISessionBackendKind.copilotCLI.isSpiked)
    #expect(!CLISessionBackendKind.codex.isSpiked)
  }

  @Test
  func everyBackendCanHostATurnBasedLoop() {
    // Turn-based is the floor: a session to type into is all it needs, so no backend is
    // ever excluded from it.
    for backend in CLISessionBackendKind.allCases {
      #expect(backend.canHost(.turnBased))
    }
    #expect(CLISessionBackendKind.hosting(.turnBased).count == CLISessionBackendKind.allCases.count)
    #expect(CLISessionBackendKind.hosting(.goalBased) == [.claudeCode])
  }

  @Test
  func aGoalBasedDraftBuildsANodeThatIsAlreadyRunning() {
    let node = NodeDraft(
      title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass")
    ).makeNode()

    #expect(node.state == .running)
    #expect(node.runsUnattended)
  }

  @Test
  func otherLoopTypesStartIdle() {
    let node = NodeDraft(
      title: "Research", loopType: .turnBased, checkDescription: "Sound?"
    ).makeNode()

    #expect(node.state == .idle)
    #expect(!node.runsUnattended)
  }

  @Test
  func aWorktreeBindingSurvivesOntoTheNode() {
    // The binding is what `ZmxSessionLauncher` uses as the session's working directory,
    // so losing it here would silently run the loop in the wrong tree.
    let worktree = WorktreeRef(
      id: "feature", repositoryPath: "/repo", worktreePath: "/repo-feature", branch: "feature")
    let node = NodeDraft(
      title: "Implement", loopType: .turnBased, checkDescription: "Correct?", worktree: worktree
    ).makeNode()

    #expect(node.worktreeBinding == worktree)
  }
}
