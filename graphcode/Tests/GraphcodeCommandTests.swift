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
    ])

    guard case .createNode(let path, let draft) = command else {
      Issue.record("expected createNode, got \(command)")
      return
    }
    #expect(path == "/tmp/x")
    #expect(draft.title == "Research")
    #expect(draft.loopType == .turnBased)
    #expect(draft.checkDescription == "Sound?")
  }

  @Test
  func creatingAGoalBasedNodeWithAPredicate() throws {
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Green", "--type", "goal",
      "--goal", "CI passes", "--predicate", "make test",
    ])

    guard case .createNode(_, let draft) = command else {
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
    ])
    guard case .createNode(_, let draft) = command else {
      Issue.record("expected a createNode command")
      return
    }
    #expect(draft.checkDescription == nil)
    #expect(draft.isValid)
  }

  @Test
  func anImpossibleBackendPairingIsRejected() throws {
    // Codex used to be the example here because it could host *nothing*. It is spiked now
    // (issue #1) and takes turn- and goal-based loops fine — but a time-based loop needs
    // the session to re-trigger itself, and Codex has no `/loop` equivalent, so that
    // pairing would run once and look like a broken schedule.
    #expect(throws: GraphcodeCommand.ParseError.invalidDraft) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/x", "--title", "Poll", "--type", "time",
        "--prompt", "/loop 1h Check", "--backend", "codex",
      ])
    }
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
  func omittingTheBackendLeavesTheChoiceToTheDaemon() throws {
    // No flag must mean no choice: the draft travels with nil so the daemon can give a
    // Copilot loop's children Copilot sessions. Hardcoding claudeCode here was the bug.
    let command = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Child", "--type", "goal",
      "--goal", "say hi",
    ])
    guard case .createNode(_, let draft) = command else {
      return #expect(Bool(false), "expected createNode, got \(command)")
    }
    #expect(draft.backend == nil)

    let explicit = try GraphcodeCommand.parse([
      "node", "create", "/tmp/x", "--title", "Child", "--type", "goal",
      "--goal", "say hi", "--backend", "copilotCLI",
    ])
    guard case .createNode(_, let explicitDraft) = explicit else {
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

    guard case .createNode(_, let draft) = command else {
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
