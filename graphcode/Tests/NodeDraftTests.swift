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
  func aTurnBasedDraftTakesACriterionButDoesNotDemandOne() {
    // It used to be required, and requiring it taught people to type "check" in the box
    // to get past the form. The hand-off this type names is a human watching the work,
    // and that human is there whether or not they wrote the criterion down first.
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?").isValid)
    #expect(NodeDraft(title: "Research", loopType: .turnBased).isValid)
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "   ").isValid)
    // A title is still the one thing every draft needs.
    #expect(!NodeDraft(title: "  ", loopType: .turnBased).isValid)
  }

  @Test
  func aTurnBasedSessionStillStopsForReviewWithoutACriterion() throws {
    let bare = try #require(
      NodeDraft(title: "Research", loopType: .turnBased).makeNode().sessionPrompt)
    #expect(bare.contains("stopping after each one"))
    #expect(!bare.contains("verified against"))
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
    // Copilot has no `/loop`-equivalent, so a time-based loop on it would run once and
    // look like a broken schedule; and no verified sub-agent fan-out, so no composites.
    #expect(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "Sound?",
        backend: .copilotCLI
      ).isValid)
    #expect(
      NodeDraft(
        title: "Ship", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
        backend: .copilotCLI
      ).isValid)
    // Time-based on Copilot is allowed now that it can re-trigger its own session; a
    // composite is the pairing that stays refused, since sub-agent fan-out is unverified.
    #expect(
      NodeDraft(
        title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
        backend: .copilotCLI
      ).isValid)
    #expect(
      !NodeDraft(title: "Triage", loopType: .proactive, backend: .copilotCLI).isValid)
  }

  @Test
  func nothingHostsALoopItCannotLaunch() {
    // The trap this closes: the app's terminal launches whatever the backend says, and for
    // an unspiked one there is nothing to launch. An earlier version allowed turn-based
    // loops on such a backend, reasoning they need only "a session to type into" — so a
    // loop labelled Codex silently opened a Claude Code session.
    //
    // Codex used to be the fixture here. It has a real adapter now (issue #1), so the
    // invariant is asserted directly instead: anything that can host a loop type has a
    // binary to launch, and anything that can't host one refuses the draft too.
    for backend in CLISessionBackendKind.allCases {
      for loopType in LoopType.allCases where backend.canHost(loopType) {
        #expect(backend.executableName != nil)
        #expect(backend.isSpiked)
      }
    }
    // Codex has no `/loop` equivalent, so the pairing is refused all the way through to
    // the draft — the same path an unspiked backend used to take for every type.
    #expect(!CLISessionBackendKind.codex.canHost(.timeBased))
    #expect(
      !NodeDraft(
        title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h", backend: .codex
      ).isValid)
  }

  @Test
  func everyBackendHasBeenSpiked() {
    // Claude Code is the reference backend; Copilot was spiked against the real CLI, and
    // Codex against 0.145.0 once it was installed (issue #1). None of these rows is
    // written from memory, which is the whole point of `isSpiked`.
    for backend in CLISessionBackendKind.allCases {
      #expect(backend.isSpiked)
    }
  }

  @Test
  func theHostingMatrixMatchesTheSpikedCapabilities() {
    // All three can host the two types that need nothing of the agent beyond a session:
    // a turn-based loop is judged by a human, and a goal's predicate is polled by the
    // daemon from outside.
    #expect(CLISessionBackendKind.hosting(.turnBased) == [.claudeCode, .copilotCLI, .codex])
    #expect(CLISessionBackendKind.hosting(.goalBased) == [.claudeCode, .copilotCLI, .codex])
    // Time-based needs the session to re-trigger itself, since graphcode holds no timer.
    // Copilot gained that; Codex has no `/loop` equivalent in its CLI surface.
    #expect(CLISessionBackendKind.hosting(.timeBased) == [.claudeCode, .copilotCLI])
    // A composite still needs sub-agent fan-out, which only Claude Code has been shown
    // to do.
    #expect(CLISessionBackendKind.hosting(.proactive) == [.claudeCode])
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
