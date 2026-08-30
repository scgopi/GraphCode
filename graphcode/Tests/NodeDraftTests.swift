import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

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
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "Sound?",
        firstInstruction: "Read the RFC"
      ).isValid)
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased, firstInstruction: "Read the RFC")
        .isValid)
    #expect(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "   ",
        firstInstruction: "Read the RFC"
      ).isValid)
  }

  @Test
  func aTurnBasedDraftDoesDemandSomethingToDo() {
    // The one field this type never had. Without it the session opened knowing it should
    // pause and what it would be judged on, and never what to start — which is not a
    // loop, it is a waiting room.
    #expect(!NodeDraft(title: "Research", loopType: .turnBased).isValid)
    #expect(
      !NodeDraft(title: "Research", loopType: .turnBased, firstInstruction: "  ").isValid)
    // A criterion is not a task: knowing what it will be judged on tells a session
    // nothing about what to begin.
    #expect(
      !NodeDraft(title: "Research", loopType: .turnBased, checkDescription: "Sound?").isValid)
  }

  @Test
  func aTurnBasedSessionIsToldTheJobThenTheShapeThenTheBar() throws {
    let full = try #require(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "Sound?",
        firstInstruction: "Read the RFC"
      ).makeNode().sessionPrompt)
    #expect(full.hasPrefix("Read the RFC"))
    #expect(full.contains("stopping after each one"))
    #expect(full.contains("verified against"))
  }

  @Test
  func pausingOnlyBeforeWritesChangesWhatTheSessionIsAskedFor() throws {
    // The radio pair is not decoration: it is the sentence the agent actually reads.
    let guarded = try #require(
      NodeDraft(
        title: "Port", loopType: .turnBased, firstInstruction: "Port the settings screen",
        pausesBeforeWritesOnly: true
      ).makeNode().sessionPrompt)
    #expect(guarded.contains("before anything that changes files"))
    #expect(!guarded.contains("stopping after each one"))
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

  /// The title used to be the one field every draft demanded, and it was the most
  /// tedious one on the form — the prompt is what the human has in their head. A blank
  /// title now creates the node as "New Loop", and the app follows up with a
  /// backend-suggested name (see `TitleSuggestionClient`).
  @Test
  func anUntitledDraftIsValidAndFallsBackToAPlaceholderName() {
    let draft = NodeDraft(
      title: "  ", loopType: .turnBased, checkDescription: "Sound?",
      firstInstruction: "Read the RFC")
    #expect(draft.isValid)
    #expect(draft.makeNode().title == "New Loop")
    // A typed title is used as typed.
    #expect(
      NodeDraft(title: "Research", loopType: .turnBased).makeNode().title == "Research")
  }

  /// The client picks the node's id, not the daemon — that's what lets the app rename
  /// the node when the suggested title arrives, without diffing broadcasts to find it.
  @Test
  func theDraftsIDBecomesTheNodesID() {
    let draft = NodeDraft(title: "Research", loopType: .turnBased)
    #expect(draft.makeNode().id == draft.id)
  }

  /// A draft serialized by a CLI that predates `id` still decodes — its node simply
  /// gets a fresh id, the way every draft's always did.
  @Test
  func aDraftWithoutAnIDStillDecodes() throws {
    let json = """
      {"title":"Research","loopType":"turnBased","backend":"claudeCode"}
      """
    let data = try #require(json.data(using: .utf8))
    let draft = try JSONDecoder().decode(NodeDraft.self, from: data)
    #expect(draft.title == "Research")
    #expect(draft.makeNode().id == draft.id)
  }

  @Test
  func aCompositeDraftNeedsOnlyATitleAndGetsAnEmptySubGraph() {
    // A composite is built by editing its sub-graph after creation, so demanding a
    // populated one up front would mean a modal that can't be filled in until the thing
    // it creates exists. The real gate is arming, not creating.
    let draft = NodeDraft(title: "Triage inbox", loopType: .composite)
    #expect(draft.isValid)
    // The name, though, is required for this type alone: every other kind gets one from
    // its own backend once it starts working, and a composite never starts. "New Loop"
    // would be its name for good.
    #expect(!NodeDraft(title: "  ", loopType: .composite).isValid)

    let node = draft.makeNode()
    #expect(node.subGraph != nil)
    #expect(node.subGraph?.nodes.isEmpty == true)
    // Created, not armed — nothing runs until it has been piloted.
    #expect(node.pilotState == .notPiloted)
    #expect(!node.pilotState.canArm)
  }

  @Test
  func onlyACompositeNodeGetsASubGraph() {
    #expect(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "?",
        firstInstruction: "Work"
      )
      .makeNode().subGraph == nil)
  }

  @Test
  func aBackendThatCannotHostTheLoopTypeIsRefused() {
    // Copilot has no `/loop`-equivalent, so a time-based loop on it would run once and
    // look like a broken schedule; and no verified sub-agent fan-out, so no composites.
    #expect(
      NodeDraft(
        title: "Research", loopType: .turnBased, checkDescription: "Sound?",
        firstInstruction: "Read the RFC", backend: .copilotCLI
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
      !NodeDraft(title: "Triage", loopType: .composite, backend: .copilotCLI).isValid)
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
    #expect(CLISessionBackendKind.codex.canHost(.timeBased))
    #expect(
      NodeDraft(
        title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check", backend: .codex
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
    // All four can host the two types that need nothing of the agent beyond a session:
    // a turn-based loop is judged by a human, and a goal's predicate is polled by the
    // daemon from outside.
    #expect(
      CLISessionBackendKind.hosting(.turnBased) == [.claudeCode, .copilotCLI, .codex, .openCode])
    #expect(
      CLISessionBackendKind.hosting(.goalBased) == [.claudeCode, .copilotCLI, .codex, .openCode])
    #expect(
      CLISessionBackendKind.hosting(.timeBased)
        == [.claudeCode, .copilotCLI, .codex, .openCode])
    // A composite still needs sub-agent fan-out, which only Claude Code has been shown
    // to do.
    #expect(CLISessionBackendKind.hosting(.composite) == [.claudeCode])
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
      title: "Research", loopType: .turnBased, checkDescription: "Sound?",
      firstInstruction: "Work"
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
      title: "Implement", loopType: .turnBased, checkDescription: "Correct?",
      firstInstruction: "Work", worktree: worktree
    ).makeNode()

    #expect(node.worktreeBinding == worktree)
  }

  @Test
  func theIntervalControlWritesTheSameDirectiveThePromptFieldUsedToHold() {
    // The old form had one free-text field whose placeholder was the whole
    // documentation — you had to know the cadence lives *inside* the prompt as a `/loop`
    // directive, and what its syntax was. What gets stored has to be identical.
    var state = ProjectFeature.State(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")))
    state.draftLoopType = .timeBased
    state.draftInterval = .hourly
    state.draftTimedTask = "Check for new crash reports"

    #expect(state.draft.triggerPrompt == "/loop 1h Check for new crash reports")
    #expect(state.draft.isValid)

    state.draftStopAfter = "20 runs"
    #expect(state.draft.triggerPrompt == "/loop 1h Check for new crash reports Stop after 20 runs.")

    state.draftInterval = .custom
    state.draftCustomInterval = "45m"
    #expect(state.draft.triggerPrompt?.hasPrefix("/loop 45m ") == true)
  }

  @Test
  func aTimedDraftWithNothingToDoIsNotValidHoweverOftenItWouldRun() {
    var state = ProjectFeature.State(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")))
    state.draftLoopType = .timeBased
    state.draftInterval = .daily

    #expect(state.draft.triggerPrompt == nil)
    #expect(!state.draft.isValid)
  }

  @Test
  func daemonOnlyBackendsRequireARealDaemonCadence() {
    for backend in [CLISessionBackendKind.codex, .openCode] {
      for prompt in ["check reports", "/loop tomorrow check reports", "/schedule daily check"] {
        #expect(
          !NodeDraft(
            title: "Poll", loopType: .timeBased, triggerPrompt: prompt, backend: backend
          ).isValid,
          "\(backend.rawValue) accepted \(prompt)")
      }
      #expect(
        NodeDraft(
          title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 30m check reports",
          backend: backend
        ).isValid)
      #expect(
        NodeDraft(
          title: "Poll", loopType: .timeBased, triggerPrompt: "check reports",
          heartbeatIntervalSeconds: 1800, backend: backend
        ).isValid)
      #expect(
        !NodeDraft(
          title: "Poll", loopType: .timeBased, triggerPrompt: "check reports",
          heartbeatIntervalSeconds: .infinity, backend: backend
        ).isValid)
    }
  }

  @Test
  func aCompositeCarriesTheScheduleItIsIntendedFor() {
    // Nothing runs at creation, so this is a statement of intent — but one the composite
    // should still be holding when someone comes back to arm it.
    var state = ProjectFeature.State(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")))
    state.draftLoopType = .composite
    state.draftTitle = "Nightly sweep"
    state.draftSchedule = .weekdays
    state.draftScheduleTime = "07:30"

    #expect(state.draft.triggerPrompt == "Intended schedule: weekdays at 07:30")
    #expect(state.draft.isValid)
  }

  @Test
  func changingTheTypeStillFallsTheBackendBack() {
    // The rule `BackendPicker.onChange` applied, now that the dialog draws the note
    // itself: an impossible pairing left selected is a form that refuses to submit
    // without saying which field is at fault.
    #expect(CLISessionBackendKind.codex.canHost(.timeBased))
    #expect(CLISessionBackendKind.hosting(.timeBased).contains(.codex))
    // And the note the dialog shows for it is the picker's own sentence, not a second
    // version of the same refusal.
    #expect(
      BackendPicker.unsupportedReason(backend: .codex, loopType: .timeBased)
        == BackendPicker.unsupportedReason(backend: .codex, loopType: .timeBased))
    #expect(CLISessionBackendKind.openCode.canHost(.timeBased))
  }

  @Test
  func aSketchDraftIsValidWhileCompletelyEmpty() {
    // The regression guard for the whole idea: `⏎` on an untouched dialog is a
    // complete action. No goal, no worktree, no prompt — it opens quiet and waits.
    let draft = NodeDraft(title: "", loopType: .sketch)
    #expect(draft.isValid)

    let node = draft.makeNode()
    #expect(node.goal == nil)
    #expect(node.worktreeBinding == nil)
    #expect(node.sessionPrompt == nil)
    #expect(node.state == .idle)
    #expect(!node.runsUnattended)
  }

  @Test
  func aSketchOpensWithItsStartingNoteWhenThereIsOne() {
    let node = NodeDraft(
      title: "", loopType: .sketch,
      firstInstruction: "where does the usage cap get read from?"
    ).makeNode()
    #expect(node.sessionPrompt == "where does the usage cap get read from?")
    // Whitespace is not a note.
    #expect(
      NodeDraft(title: "", loopType: .sketch, firstInstruction: "   ")
        .makeNode().sessionPrompt == nil)
  }

  @Test
  func everyBackendHostsASketch() {
    // A bare session is the least demanding type — nothing to refuse over.
    for backend in CLISessionBackendKind.allCases {
      #expect(backend.canHost(.sketch))
    }
  }

  @Test
  func theChooserOrdersTypesByCommitmentSketchFirst() {
    // `allCases` is the chooser's order and the ⌘1–⌘5 shortcut order; a reshuffle
    // silently rebinds every shortcut.
    #expect(
      LoopType.allCases == [.sketch, .goalBased, .timeBased, .turnBased, .composite])
  }
}
