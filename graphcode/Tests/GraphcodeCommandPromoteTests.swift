import Foundation
import GraphcodeKit
import Testing

/// `node promote` parsing — split from `GraphcodeCommandTests` only for size; the
/// contract is the same: a malformed command earns a named error, never an exit 0
/// that quietly did nothing.
@Suite
struct GraphcodeCommandPromoteTests {
  @Test
  func promoteParsesEachTargetsOneDecision() throws {
    let id = UUID()
    #expect(
      try GraphcodeCommand.parse([
        "node", "promote", "/tmp/x", id.uuidString, "--type", "goal",
        "--goal", "the flake is fixed", "--predicate", "make test",
      ])
        == .promoteNode(
          projectPath: "/tmp/x", nodeID: id,
          promotion: .goal(GoalSpec(summary: "the flake is fixed", predicate: "make test"))))
    #expect(
      try GraphcodeCommand.parse([
        "node", "promote", "/tmp/x", id.uuidString, "--type", "turn",
        "--pause", "before-writes",
      ])
        == .promoteNode(
          projectPath: "/tmp/x", nodeID: id, promotion: .turn(pausesBeforeWritesOnly: true)))
    // Turn's default matches the app's form: pause after every turn.
    #expect(
      try GraphcodeCommand.parse(["node", "promote", "/tmp/x", id.uuidString, "--type", "turn"])
        == .promoteNode(
          projectPath: "/tmp/x", nodeID: id, promotion: .turn(pausesBeforeWritesOnly: false)))
    #expect(
      try GraphcodeCommand.parse([
        "node", "promote", "/tmp/x", id.uuidString, "--type", "time",
        "--prompt", "/loop 1h triage",
      ])
        == .promoteNode(
          projectPath: "/tmp/x", nodeID: id, promotion: .timed(triggerPrompt: "/loop 1h triage")))
  }

  /// The decision each target needs is required at parse time, so the CLI can say
  /// what's missing instead of sending a promotion the daemon must refuse.
  @Test
  func promoteWithoutItsDecisionIsRefused() {
    let id = UUID().uuidString
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("--type")) {
      _ = try GraphcodeCommand.parse(["node", "promote", "/tmp/x", id])
    }
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("--goal")) {
      _ = try GraphcodeCommand.parse(["node", "promote", "/tmp/x", id, "--type", "goal"])
    }
    #expect(throws: GraphcodeCommand.ParseError.missingArgument("--prompt")) {
      _ = try GraphcodeCommand.parse(["node", "promote", "/tmp/x", id, "--type", "time"])
    }
    #expect(
      throws: GraphcodeCommand.ParseError.invalidValue(argument: "--pause", value: "sometimes")
    ) {
      _ = try GraphcodeCommand.parse([
        "node", "promote", "/tmp/x", id, "--type", "turn", "--pause", "sometimes",
      ])
    }
  }

  /// Demotion and composite have no CLI spelling for the same reason they have no wire
  /// shape (`SketchPromotion`): refused at parse, before a daemon is even dialled.
  @Test
  func promoteRefusesTargetsThatAreNotAPromotion() {
    let id = UUID().uuidString
    for target in ["sketch", "composite"] {
      #expect(
        throws: GraphcodeCommand.ParseError.invalidValue(argument: "--type", value: target)
      ) {
        _ = try GraphcodeCommand.parse(["node", "promote", "/tmp/x", id, "--type", target])
      }
    }
  }
}
