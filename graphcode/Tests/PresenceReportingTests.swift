import Foundation
import Testing

@testable import GraphcodeKit

/// Presence, end to end: the hooks a backend is handed, the flag that points it at them,
/// and what a card does with the reading that comes back.
///
/// The failure this suite exists to keep closed is not a crash. `Presence` and
/// `ZmxSessionLauncher.presence` shipped complete and were called by nothing, so a
/// goal-based loop read RUNNING from the moment it was created until a human stopped it —
/// pulsing dot and all — whether its agent was working or had answered and gone quiet an
/// hour earlier. Every assertion here is one link in the chain that was missing.
@Suite
struct PresenceReportingTests {
  private let zmx = "/Users/someone/.graphcode/bin/zmx"

  private func hooks(_ backend: CLISessionBackendKind = .claudeCode, zmxPath: String? = nil)
    -> [String: Any]?
  {
    guard let json = PresenceHooks.json(forBackend: backend, zmxPath: zmxPath ?? zmx),
      let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let hooks = parsed["hooks"] as? [String: Any]
    else { return nil }
    return hooks
  }

  /// The command a given event runs, dug out of the shape Claude Code expects.
  private func command(
    for event: String, _ backend: CLISessionBackendKind = .claudeCode, zmxPath: String? = nil
  ) -> String? {
    guard let matchers = hooks(backend, zmxPath: zmxPath)?[event] as? [[String: Any]],
      let entries = matchers.first?["hooks"] as? [[String: Any]]
    else { return nil }
    return entries.first?["command"] as? String
  }

  @Test
  func claudeCodeReportsEveryStateItCanDistinguish() {
    #expect(command(for: "SessionStart")?.contains("presence=busy") == true)
    #expect(command(for: "UserPromptSubmit")?.contains("presence=busy") == true)
    #expect(command(for: "PreToolUse")?.contains("presence=busy") == true)
    #expect(command(for: "Notification")?.contains("presence=awaitingInput") == true)
    #expect(command(for: "Stop")?.contains("presence=idle") == true)
    #expect(command(for: "SessionEnd")?.contains("presence=absent") == true)
  }

  @Test
  func aSubagentFinishingIsNotTheLoopFinishing() {
    // `SubagentStop` fires while the main agent is still working. Reporting idle there
    // would blank a card in the middle of a fan-out — the same lie as reporting running
    // for a loop that has stopped, pointed the other way.
    #expect(hooks()?["SubagentStop"] == nil)
  }

  @Test
  func aHookCanNeverFailTheThingItIsReporting() {
    // Claude Code reads a hook's exit status, and a non-zero one from `Stop` blocks the
    // very stop being reported. Every body ends by succeeding on purpose.
    for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop"] {
      #expect(command(for: event)?.hasSuffix("exit 0") == true)
    }
  }

  @Test
  func aSessionGraphcodeDidNotStartIsLeftAlone() {
    // The file can reach a session with no zmx label store behind it. Writing there is an
    // error on a human's own terminal, so the guard comes first.
    #expect(command(for: "Stop")?.hasPrefix("if [ -n \"$ZMX_SESSION\" ]") == true)
  }

  @Test
  func aSupportDirectoryWithAQuoteInItIsAPathNotSyntax() {
    let awkward = "/Users/o'brien/.graphcode/bin/zmx"
    // Read back through the parser, not off the raw text: the file has to survive being
    // JSON *and* being shell, and asserting on the encoded form would only prove the
    // encoder escaped its own backslash.
    let body = command(for: "Stop", zmxPath: awkward)

    #expect(body?.contains(#"'/Users/o'\''brien/.graphcode/bin/zmx'"#) == true)
  }

  @Test
  func theFlagPointsAtTheFileRatherThanCarryingIt() {
    // By path, because `zmx` types the launch command into a tty capped at `MAX_CANON`
    // and the hook bodies are several hundred bytes of shell.
    let file = URL(fileURLWithPath: "/tmp/hooks.json")
    #expect(
      CLISessionBackendKind.claudeCode.presenceArguments(hooksFile: file)
        == ["--settings", "/tmp/hooks.json"])
    #expect(CLISessionBackendKind.claudeCode.presenceArguments(hooksFile: nil) == [])
  }

  @Test
  func theFlagRidesOnTheLaunchEvenWithNoPrompt() {
    // `launchArguments` returns early when there is no prompt, and an early return that
    // dropped the hooks would leave exactly the attached sessions a human watches most
    // closely unable to report anything.
    let arguments = CLISessionBackendKind.claudeCode.launchArguments(
      prompt: nil, tier: .standard, hooksFile: URL(fileURLWithPath: "/tmp/hooks.json"))
    #expect(arguments.contains("--settings"))
  }

  // MARK: - What a card does with the reading

  private func node(_ state: LoopState, _ presence: Presence?) -> LoopNode {
    LoopNode(
      title: "Fix the top crash",
      loopType: .goalBased,
      goal: GoalSpec(summary: "Crash rate under 1%"),
      presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
      state: state)
  }

  private func node(_ state: LoopState, _ presence: Presence?, activeDependents: Bool) -> LoopNode {
    var n = node(state, presence)
    n.hasActiveDependents = activeDependents
    return n
  }

  @Test
  func aLoopThatFinishedItsTurnStopsClaimingToRun() {
    // The reported complaint, in one assertion.
    #expect(node(.running, .idle).displayState == .idle)
    #expect(node(.running, .busy).displayState == .running)
  }

  @Test
  func aSessionWaitingOnAHumanSaysSo() {
    // docs: "A node can be `.running` in the graph and `.awaitingInput` in its session —
    // that combination is precisely what the needs-attention rollup exists to surface."
    #expect(node(.running, .awaitingInput).displayState == .awaitingInput)
  }

  @Test
  func aVanishedSessionIsNotWorkEither() {
    #expect(node(.running, .absent).displayState == .idle)
  }

  @Test
  func aQuietSessionWithActiveDependentsIsWaiting() {
    #expect(node(.running, .idle, activeDependents: true).displayState == .waiting)
    #expect(node(.running, .absent, activeDependents: true).displayState == .waiting)
    #expect(node(.running, .busy, activeDependents: true).displayState == .running)
  }

  @Test
  func nothingElseIsSecondGuessedByASessionReading() {
    // Every other state is a fact about the loop's place in the graph. A `.blocked` node
    // is waiting on an edge whether or not its session breathes, and a `.succeeded` one
    // is finished whatever is still running in its pane.
    for state in LoopState.allCases where state != .running {
      #expect(node(state, .busy).displayState == state)
      #expect(node(state, .idle).displayState == state)
    }
  }

  @Test
  func abackendThatReportsNothingChangesNothing() {
    // Copilot and Codex have no hook file to be handed yet, and a session that has never
    // been polled has no reading. Both must look exactly like the behaviour that shipped
    // before presence was wired at all.
    #expect(node(.running, nil).displayState == .running)
    #expect(PresenceHooks.json(forBackend: .copilotCLI, zmxPath: zmx) == nil)
    #expect(PresenceHooks.json(forBackend: .codex, zmxPath: zmx) == nil)
    #expect(
      CLISessionBackendKind.copilotCLI.presenceArguments(
        hooksFile: URL(fileURLWithPath: "/tmp/hooks.json")) == [])
  }

  @Test
  func aReadingSurvivesTheWire() throws {
    // The daemon encodes presence into the graph it sends to clients. The decoder must
    // preserve it, or every surface sees `.running` for a loop whose agent stopped an
    // hour ago — the exact failure the presence system was built to fix.
    let encoded = try JSONEncoder().encode(node(.running, .busy))
    let decoded = try JSONDecoder().decode(LoopNode.self, from: encoded)

    #expect(decoded.presence?.presence == .busy)
    #expect(decoded.displayState == .running)

    let idleEncoded = try JSONEncoder().encode(node(.running, .idle))
    let idleDecoded = try JSONDecoder().decode(LoopNode.self, from: idleEncoded)

    #expect(idleDecoded.presence?.presence == .idle)
    #expect(idleDecoded.displayState == .idle)
  }
}
