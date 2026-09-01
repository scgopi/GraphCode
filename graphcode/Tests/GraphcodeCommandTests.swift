import Foundation
import GraphcodeKit
import Testing

/// The `graphcode` CLI's parsing and rendering (docs/03-architecture.md#cli-graphcode).
///
/// Tested here rather than by spawning the binary because the interesting behaviour is
/// all in the parse: what a malformed command does is the difference between a useful
/// error and a command that exits 0 having quietly done nothing.
@Suite
struct GraphcodeCommandTests {
  @Test
  func noArgumentsShowsHelpRatherThanFailing() throws {
    #expect(try GraphcodeCommand.parse([]) == .help)
    #expect(try GraphcodeCommand.parse(["--help"]) == .help)
  }

  @Test
  func statusTakesAProjectPath() throws {
    #expect(try GraphcodeCommand.parse(["status", "/tmp/x"]) == .status(projectPath: "/tmp/x"))
  }

  @Test
  func aMissingProjectPathIsNamedInTheError() throws {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["status"])
    }
  }

  @Test
  func creatingATurnBasedNode() throws {
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Research", "--type", "turn", "--check", "Sound?",
      "--prompt", "Read the RFC",
    ])

    guard case .createNode(let path, let draft, _) = command else {
      Issue.record("expected createNode, got \(command)")
      return
    }
    #expect(path == "/tmp/x")
    #expect(draft.title == "Research")
    #expect(draft.loopType == .turnBased)
    #expect(draft.checkDescription == "Sound?")
    // `--prompt` is the task for this type too — one flag for "what to do", rather than
    // a second one meaning the same thing under another name.
    #expect(draft.firstInstruction == "Read the RFC")
  }

  @Test
  func creatingAGoalBasedNodeWithAPredicate() throws {
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Green", "--type", "goal",
      "--goal", "CI passes", "--predicate", "make test",
    ])

    guard case .createNode(_, let draft, _) = command else {
      Issue.record("expected createNode")
      return
    }
    #expect(draft.goal?.summary == "CI passes")
    #expect(draft.goal?.effectivePredicate == "make test")
  }

  @Test
  func anIncompleteDraftIsRejectedBeforeItReachesTheDaemon() throws {
    // Exiting 0 on a command that silently created nothing is the failure mode this
    // prevents — the same rule the daemon enforces, applied early enough to explain.
    // A goal with no summary describes nothing, so it stays refused.
    #expect(throws: GraphcodeCommand.ParseError.invalidDraft) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "Research", "--type", "goal",
      ])
    }
  }

  @Test
  func aTurnBasedNodeNeedsNoCriterionOnTheCommandLine() throws {
    // The criterion became optional: requiring it only taught people to pass `--check x`
    // to get past the validation. The human verifying each turn is the hand-off, and they
    // are there whether or not they wrote down what they would look for.
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Research", "--type", "turn",
      "--prompt", "Read the RFC",
    ])
    guard case .createNode(_, let draft, _) = command else {
      Issue.record("expected a createNode command")
      return
    }
    #expect(draft.checkDescription == nil)
    #expect(draft.isValid)
  }

  @Test
  func aTurnBasedNodeStillNeedsSomethingToDo() {
    // The other half of the same rule: no criterion is fine, no task is not. The CLI
    // says so at parse time rather than exiting 0 on a command that quietly did nothing.
    #expect(throws: GraphcodeCommand.ParseError.invalidDraft) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "Research", "--type", "turn",
      ])
    }
  }

  @Test
  func aDaemonBackedCodexTimeLoopIsAccepted() throws {
    // Codex has no in-session recurrence, but a leading simple directive is converted to
    // the graphcode daemon cadence rather than rejected as an unsupported pairing.
    #expect(
      throws: Never.self,
      performing: {
        try GraphcodeCommand.parse([
          "node", "create", "/tmp/x", "--title", "Poll", "--type", "time",
          "--prompt", "/loop 1h Check", "--backend", "codex",
        ])
      })
    // And the pairing that is fine now, which is the point of the change.
    #expect(
      throws: Never.self,
      performing: {
        try GraphcodeCommand.parse([
          "node", "create", "/tmp/x", "--title", "Green", "--type", "goal",
          "--goal", "CI passes", "--backend", "codex",
        ])
      })
  }

  @Test
  func deleteParsesLikeEveryOtherNodeVerb() throws {
    // Deletion existed on the wire since the app grew it; the CLI just had no verb —
    // which left agents stopping loops they meant to remove, and humans in the sidebar.
    let id = UUID()
    let command = try GraphcodeCommand.parse([
      "node", "delete", "/tmp/x", id.uuidString,
    ])
    #expect(command == .deleteNode(projectPath: "/tmp/x", nodeID: id))
  }

  @Test
  func omittingTheBackendLeavesTheChoiceToTheDaemon() throws {
    // No flag must mean no choice: the draft travels with nil so the daemon can give a
    // Copilot loop's children Copilot sessions. Hardcoding claudeCode here was the bug.
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Child", "--type", "goal",
      "--goal", "say hi",
    ])
    guard case .createNode(_, let draft, _) = command else {
      return #expect(Bool(false), "expected createNode, got \(command)")
    }
    #expect(draft.backend == nil)

    let explicit = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Child", "--type", "goal",
      "--goal", "say hi", "--backend", "copilotCLI",
    ])
    guard case .createNode(_, let explicitDraft, _) = explicit else {
      return #expect(Bool(false), "expected createNode, got \(explicit)")
    }
    #expect(explicitDraft.backend == .copilotCLI)
  }

  @Test
  func anUnknownEnumValueNamesTheOffendingFlag() throws {
    #expect(
      throws: GraphcodeCommand.ParseError.invalidValue(argument: "--type", value: "sideways")
    ) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "x", "--type", "sideways",
      ])
    }
  }

  @Test
  func modelTierCanBePinnedFromTheShell() throws {
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Poll", "--type", "time",
      "--prompt", "/loop 1h Check", "--model", "capable",
    ])

    guard case .createNode(_, let draft, _) = command else {
      Issue.record("expected createNode")
      return
    }
    #expect(draft.modelTier == .capable)
  }

  @Test
  func creatingAnEdgeWithAKindAndCondition() throws {
    let from = UUID()
    let to = UUID()
    let command = try GraphcodeCommand.parse([
      "edge", "create", "/tmp/x", from.uuidString, to.uuidString,
      "--kind", "message", "--condition", "onSuccess",
    ])

    #expect(
      command
        == .createEdge(
          projectPath: "/tmp/x", from: from, to: to,
          spec: EdgeSpec(kind: .message, condition: .onSuccess)))
  }

  @Test
  func edgeDefaultsMatchTheCanvasDefaults() throws {
    let from = UUID()
    let to = UUID()
    let command = try GraphcodeCommand.parse([
      "edge", "create", "/tmp/x", from.uuidString, to.uuidString,
    ])

    #expect(
      command == .createEdge(projectPath: "/tmp/x", from: from, to: to, spec: EdgeSpec()))
  }

  @Test
  func aMalformedUUIDIsReported() throws {
    #expect(
      throws: GraphcodeCommand.ParseError.invalidValue(argument: "from-id", value: "nope")
    ) {
      try GraphcodeCommand.parse(["edge", "create", "/tmp/x", "nope", UUID().uuidString])
    }
  }

  @Test
  func stoppingANode() throws {
    let nodeID = UUID()
    #expect(
      try GraphcodeCommand.parse(["node", "stop", "/tmp/x", nodeID.uuidString])
        == .stopNode(projectPath: "/tmp/x", nodeID: nodeID))
  }

  @Test
  func restartingANodeAndEverySession() throws {
    let nodeID = UUID()
    #expect(
      try GraphcodeCommand.parse(["node", "restart", "/tmp/x", nodeID.uuidString])
        == .restartNode(projectPath: "/tmp/x", nodeID: nodeID))
    #expect(
      try GraphcodeCommand.parse(["sessions", "restart", "/tmp/x"])
        == .restartSessions(projectPath: "/tmp/x"))
    #expect(throws: GraphcodeCommand.ParseError.self) {
      try GraphcodeCommand.parse(["sessions", "stop", "/tmp/x"])
    }
  }

  @Test
  func pilotingAndArmingAComposite() throws {
    let nodeID = UUID()
    #expect(
      try GraphcodeCommand.parse(["node", "pilot", "/tmp/x", nodeID.uuidString])
        == .pilotComposite(projectPath: "/tmp/x", nodeID: nodeID))
    #expect(
      try GraphcodeCommand.parse(["node", "arm", "/tmp/x", nodeID.uuidString])
        == .armComposite(projectPath: "/tmp/x", nodeID: nodeID))
  }

  @Test
  func theGlobalGraphIsAddressableLikeAnyProject() throws {
    // The reserved path is just a path as far as the CLI is concerned — that sameness is
    // what keeps the global graph from needing its own verbs.
    #expect(
      try GraphcodeCommand.parse(["status", LoopGraphScope.globalPath])
        == .status(projectPath: LoopGraphScope.globalPath))
  }

  @Test
  func aSpawnEdgeCanNameATargetProject() throws {
    let from = UUID()
    let to = UUID()
    let command = try GraphcodeCommand.parse([
      "edge", "create", LoopGraphScope.globalPath, from.uuidString, to.uuidString,
      "--kind", "spawn", "--into", "/tmp/target",
    ])

    guard case .createEdge(_, _, _, let spec) = command else {
      Issue.record("expected createEdge")
      return
    }
    #expect(spec.kind == .spawn)
    #expect(spec.spawnTargetProjectPath == "/tmp/target")
  }

  @Test
  func usageOutputAlwaysStatesItsCoverage() {
    // A bare total would read as the whole bill when it might be a fraction of one.
    let reporting = LoopNode(
      title: "A", usage: UsageSample(inputTokens: 100, outputTokens: 20, costUSD: 0.01))
    let silent = LoopNode(title: "B")
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/x", name: "x"), nodes: [reporting, silent])

    let output = GraphcodeCommand.renderUsage(graph)

    #expect(output.contains("1/2 loops reporting"))
    #expect(output.contains("$0.0100"))
  }

  @Test
  func usageOutputSaysWhenNothingReportedAndHowToFixIt() {
    // "No usage reported" plus the hook that would change that — a silent zero would be
    // a number nobody measured.
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/x", name: "x"), nodes: [LoopNode(title: "A")])

    let output = GraphcodeCommand.renderUsage(graph)

    #expect(output.contains("no usage reported"))
    #expect(output.contains("zmx set"))
  }

  @Test
  func anUnknownVerbIsNamed() throws {
    #expect(throws: GraphcodeCommand.ParseError.unknownCommand("frobnicate")) {
      try GraphcodeCommand.parse(["frobnicate"])
    }
  }

  @Test
  func renderingAGraphShowsFullNodeIDs() {
    // The ids are what every other subcommand takes as input, so truncating them would
    // look tidier and be useless.
    let node = LoopNode(title: "Research", checkDescription: "Sound?", state: .failed)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/x", name: "x"), nodes: [node])

    let output = GraphcodeCommand.render(graph)

    #expect(output.contains(node.id.uuidString))
    #expect(output.contains("Research"))
    #expect(output.contains("Failed"))
  }

  @Test
  func renderingAGraphShowsTheBackendExitCode() {
    let node = LoopNode(
      title: "Trust dialog", loopType: .goalBased, goal: GoalSpec(summary: "work"),
      presence: PresenceReading(presence: .idle, confidence: .scanned, exitCode: 1),
      state: .running)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/x", name: "x"), nodes: [node])

    let output = GraphcodeCommand.render(graph)

    #expect(output.contains("failed"))
    #expect(output.contains("session exited (1)"))
  }

  @Test
  func renderingAnEmptyGraphSaysSoRatherThanPrintingNothing() {
    let output = GraphcodeCommand.render(
      LoopGraph(project: ProjectRef(path: "/tmp/x", name: "x")))

    #expect(output.contains("no loops yet"))
  }

  @Test
  func sendJoinsEverythingAfterTheIDIntoOneMessage() throws {
    let id = UUID()
    let command = try GraphcodeCommand.parse([
      "node", "send", "/tmp/p", id.uuidString, "tests", "are", "green,", "ship", "it",
    ])
    #expect(
      command
        == .sendMessage(projectPath: "/tmp/p", nodeID: id, text: "tests are green, ship it"))
  }

  @Test
  func sendWithoutAMessageIsRefused() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("message")) {
      _ = try GraphcodeCommand.parse(["node", "send", "/tmp/p", UUID().uuidString])
    }
  }

}

// Trailing tests live out here for the same reason every other type at the size
// budget keeps helpers in an extension — Swift Testing discovers them all the same.
extension GraphcodeCommandTests {
  /// Asking a subcommand for help used to fail with "missing project-path" — the one
  /// moment a caller admits they don't know the arguments was the one moment they had to
  /// supply them.
  @Test
  func askingASubcommandForHelpShowsHelp() throws {
    #expect(try GraphcodeCommand.parse(["node", "create", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["node", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["status", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["usage", "-h"]) == .help)
    #expect(try GraphcodeCommand.parse(["edge", "create", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["node", "send", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["reap", "--help"]) == .help)
    #expect(try GraphcodeCommand.parse(["reap", "-h"]) == .help)
  }

  @Test
  func unknownOptionsAreRefusedBeforeMutatingCommandsRun() {
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--dryrun")) {
      try GraphcodeCommand.parse(["reap", "--dryrun"])
    }
    #expect(throws: GraphcodeCommand.ParseError.unknownOption("--titlle")) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/p", "--titlle", "Research", "--type", "turn",
        "--prompt", "Read",
      ])
    }
  }

  @Test
  func helpAmongTheFlagsShowsHelpRatherThanReportingAMissingTitle() throws {
    #expect(try GraphcodeCommand.parse(["node", "create", "/tmp/p", "--help"]) == .help)
    #expect(
      try GraphcodeCommand.parse([
        "node", "update", "/tmp/p", UUID().uuidString, "--help",
      ]) == .help)
  }

  /// The counterweight to the two tests above: everything after a `send`/`memo` id is the
  /// message, so `--help` there is text somebody wants transmitted, not a request for help.
  @Test
  func helpInsideAMessageStaysPartOfTheMessage() throws {
    let id = UUID()
    #expect(
      try GraphcodeCommand.parse(["node", "send", "/tmp/p", id.uuidString, "try", "--help"])
        == .sendMessage(projectPath: "/tmp/p", nodeID: id, text: "try --help"))
    #expect(
      try GraphcodeCommand.parse([
        "node", "memo", "/tmp/p", id.uuidString, "--help", "is", "broken",
      ])
        == .memoNode(projectPath: "/tmp/p", nodeID: id, text: "--help is broken"))
    // The sharpest version: `--help` as the whole message, with nothing around it to hint
    // that it was meant literally.
    #expect(
      try GraphcodeCommand.parse(["node", "send", "/tmp/p", id.uuidString, "--help"])
        == .sendMessage(projectPath: "/tmp/p", nodeID: id, text: "--help"))
  }

  /// A missing argument is still a missing argument — the help check must not swallow it.
  @Test
  func aMissingProjectPathIsStillAnErrorWhenNoHelpWasAsked() {
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("project-path")) {
      try GraphcodeCommand.parse(["node", "create"])
    }
  }

  @Test
  func creatingALoopInsideAComposite() throws {
    // The CLI had no way to put a loop inside a composite at all, so the type could be
    // created and never filled. `--into` addresses the same command at its sub-graph.
    let composite = UUID()
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Classify", "--type", "goal",
      "--goal", "Sort the queue", "--into", composite.uuidString,
    ])

    guard case .createNode(_, let draft, let into) = command else {
      Issue.record("expected createNode, got \(command)")
      return
    }
    #expect(into == composite)
    #expect(draft.title == "Classify")
  }

  @Test
  func compositeIsCreatableFromTheCLIUnderEitherName() throws {
    // `proactive` too: that is what a composite still serialises as, so it is the word a
    // human reading an existing graph off disk has in front of them.
    for spelling in ["composite", "proactive"] {
      let command = try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "Nightly sweep", "--type", spelling,
      ])
      guard case .createNode(_, let draft, _) = command else {
        Issue.record("expected createNode for --type \(spelling), got \(command)")
        return
      }
      #expect(draft.loopType == .composite)
    }
  }

  @Test
  func anIntoThatIsNotAUUIDIsRefused() {
    #expect(
      throws: GraphcodeCommand.ParseError.invalidValue(argument: "--into", value: "Releaser")
    ) {
      _ = try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "T", "--type", "goal", "--goal", "G",
        "--into", "Releaser",
      ])
    }
  }
}
