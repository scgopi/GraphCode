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

  // MARK: - What the session is doing

  /// Every command a given event runs, not just the first: `PreToolUse` reports a presence
  /// *and* runs the activity reporter, and the two are separate on purpose.
  private func commands(for event: String, zmxPath: String? = nil) -> [String] {
    guard let matchers = hooks(.claudeCode, zmxPath: zmxPath)?[event] as? [[String: Any]],
      let entries = matchers.first?["hooks"] as? [[String: Any]]
    else { return [] }
    return entries.compactMap { $0["command"] as? String }
  }

  /// Runs the generated reporter the way Claude Code runs it — `/bin/sh`, the hook payload
  /// on stdin — against a `zmx` that records what it was asked to set. The label it wrote,
  /// or `nil` if it wrote nothing.
  ///
  /// Through a real shell rather than by asserting on the script's text: the whole risk in
  /// this file is that a `sed` expression survives being Swift, being JSON and being shell
  /// and still doesn't match what a hook actually receives.
  private func reportedLabel(for payload: String) throws -> String? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-activity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let recording = directory.appendingPathComponent("set.txt")
    let fakeZmx = directory.appendingPathComponent("zmx")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(recording.path)'\n"
      .write(to: fakeZmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

    let script = directory.appendingPathComponent("activity.sh")
    try PresenceHooks.activityScript(zmxPath: fakeZmx.path)
      .write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.environment = ["ZMX_SESSION": "graphcode-test", "PATH": "/usr/bin:/bin"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(payload.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()

    // Never non-zero: `PreToolUse` treats 2 as "block this tool call" and anything else
    // non-zero as an error to print over the human's own session.
    #expect(process.terminationStatus == 0)
    guard let recorded = try? String(contentsOf: recording, encoding: .utf8),
      let line = recorded.split(separator: "\n").last,
      let label = line.split(separator: " ").last.map(String.init)
    else { return nil }
    return label
  }

  /// What a card would show for a payload — both halves of the channel, since an encoding
  /// the reader can't undo is the same bug as no encoding at all.
  private func activity(for payload: String) throws -> String? {
    guard let label = try reportedLabel(for: payload) else { return nil }
    return ZmxSessionLauncher.parseActivityLabel(label)
  }

  private func payload(tool: String, _ input: String) -> String {
    """
    {"session_id":"a","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"\(tool)",\
    "tool_input":\(input),"tool_use_id":"toolu_1"}
    """
  }

  @Test
  func aToolCallSaysWhatItIsDoingToWhat() throws {
    // The complaint this answers: eight loops, all of them RUNNING, none of them saying
    // what they were running.
    #expect(
      try activity(for: payload(tool: "Edit", #"{"file_path":"/w/GraphStore.swift"}"#))
        == "editing GraphStore.swift")
    #expect(
      try activity(for: payload(tool: "Read", #"{"file_path":"/w/docs/04-cli-backends.md"}"#))
        == "reading 04-cli-backends.md")
    #expect(
      try activity(for: payload(tool: "Bash", #"{"command":"make check","description":"gate"}"#))
        == "running make check")
    #expect(
      try activity(for: payload(tool: "Grep", #"{"pattern":"refreshActivity"}"#))
        == "searching for refreshActivity")
    #expect(
      try activity(for: payload(tool: "Task", #"{"description":"Find flaky tests"}"#))
        == "delegating Find flaky tests")
  }

  @Test
  func aToolNobodyMappedStillSaysSomething() throws {
    // A card reading "using WebSearch" is worth more than a card reading nothing, and the
    // set of tools is not ours to keep up with.
    #expect(try activity(for: payload(tool: "ExitPlanMode", "{}")) == "using ExitPlanMode")
    #expect(
      try activity(for: payload(tool: "mcp__playwright__browser_click", "{}"))
        == "using browser_click")
  }

  @Test
  func aPayloadWithNoToolInItReportsNothing() throws {
    // `k=` is how `zmx` removes a label, so the card falls back to what the loop was
    // handed rather than keeping the last sentence forever.
    #expect(try reportedLabel(for: "{}") == "activity=")
    #expect(try activity(for: "{}") == nil)
  }

  @Test
  func theLabelOnlyEverHoldsCharactersZmxWillKeep() throws {
    // `zmx` takes `[A-Za-z0-9._-]` in a value and silently truncates at the first space:
    // `activity=editing Loop.swift` stores `editing`. Everything else is encoded, and
    // this is the assertion that says so for a deliberately hostile command.
    let hostile = payload(
      tool: "Bash", #"{"command":"git log --oneline | grep 'fix: don_t' > /tmp/x"}"#)
    let label = try #require(try reportedLabel(for: hostile))
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
      .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-="))

    #expect(label.unicodeScalars.allSatisfy(allowed.contains))
    // And it still reads as a sentence on the other side.
    #expect(try activity(for: hostile)?.hasPrefix("running git log") == true)
  }

  @Test
  func anUnderscoreSurvivesTheRoundTrip() {
    // The one character the encoding has to escape as well as spaces, or every
    // `snake_case` filename comes back mangled — `_5F` is a literal underscore.
    #expect(
      ZmxSessionLauncher.decodedActivity("editing_20loop_5Fnode.swift") == "editing loop_node.swift"
    )
    // A value written before the encoding existed, or by hand, is text.
    #expect(ZmxSessionLauncher.decodedActivity("thinking") == "thinking")
    #expect(ZmxSessionLauncher.decodedActivity("a_zz") == "a_zz")
    // And an escape naming a control character is text too, not a control character on a
    // card: the writer only ever emits printable ones.
    #expect(ZmxSessionLauncher.decodedActivity("bell_07here") == "bell_07here")
  }

  @Test
  func onlyAToolCallKnowsWhatASessionIsDoing() {
    // Every other event clears the label in the same write that reports its presence: a
    // card reading "editing GraphStore.swift" under an IDLE pill is the same stale claim
    // the presence work took out of the pill.
    for event in ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"] {
      #expect(command(for: event)?.contains("activity=") == true)
    }
    #expect(command(for: "PreToolUse")?.contains("activity=") == false)
  }

  @Test
  func theReporterRidesBesideThePresenceReportRatherThanInsideIt() throws {
    // Presence is what the pill, the attention rollup and `MessageBus.deliverability` key
    // off. It must not stop being reported because the reporter of a nicety went wrong —
    // hence two commands, and hence the guard that makes a missing file a no-op instead
    // of a hook error printed over someone's turn.
    let bodies = commands(for: "PreToolUse")

    #expect(bodies.count == 2)
    #expect(bodies.first?.contains("presence=busy") == true)
    #expect(bodies.last?.hasPrefix("if [ -r ") == true)
    #expect(bodies.last?.contains("activity.sh") == true)
    #expect(bodies.last?.hasSuffix("exit 0") == true)
  }

  @Test
  func aRemoteSessionIsHandedTheReporterTooNotJustTheSettingsThatNameIt() throws {
    let fragment = try #require(PresenceHooks.remoteWriteFragment())

    // The script itself, written on the host where it will run — a settings file naming a
    // path that was never created is a silent no-op on every remote loop.
    #expect(fragment.contains("$HOME/.graphcode/hooks/activity.sh"))
    #expect(fragment.contains("tool_name"))
    // And by bare name there, because that host's `zmx` is not at this Mac's path.
    #expect(fragment.contains("/Users/") == false)
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
    // Within the boot grace a young loop's first poll can legitimately find no session
    // — the ensure is fired, not awaited — so it reads as quiet, not dead.
    #expect(node(.running, .absent).displayState == .idle)
  }

  @Test
  func aGoneSessionOnAnUnattendedLoopPastTheGraceIsFailed() {
    // Issue #215: a goal loop whose agent exited on its first turn showed IDLE — the
    // one word it must not show, since nothing is waiting for work. Past the boot
    // grace, `absent` is a session that died unattended, and FAILED is the word the
    // graph would have used had anyone seen the exit.
    let dead = LoopNode(
      title: "Fix the top crash", loopType: .goalBased,
      goal: GoalSpec(summary: "Crash rate under 1%"),
      presence: PresenceReading(presence: .absent, confidence: .reported), state: .running,
      createdAt: Date().addingTimeInterval(-LoopNode.absentSessionGraceSeconds - 5))
    #expect(dead.displayState == .failed)
  }

  @Test
  func anAttendedLoopWithAGoneSessionStaysIdle() {
    // A turn-based loop is a human's session — the pane they open is where its exit
    // shows; the presence poll does not overrule that.
    let attended = LoopNode(
      title: "Sketch", loopType: .turnBased, triggerPrompt: "hi",
      presence: PresenceReading(presence: .absent, confidence: .reported), state: .running,
      createdAt: Date().addingTimeInterval(-LoopNode.absentSessionGraceSeconds - 5))
    #expect(attended.displayState == .idle)
  }

  @Test
  func aLoopOthersWaitOnShowsWaitingEvenWhenGone() {
    // The waiting word is about the dependents, whose edges are the graph's business.
    let dead = LoopNode(
      title: "Fix the top crash", loopType: .goalBased,
      goal: GoalSpec(summary: "Crash rate under 1%"),
      presence: PresenceReading(presence: .absent, confidence: .reported), state: .running,
      createdAt: Date().addingTimeInterval(-LoopNode.absentSessionGraceSeconds - 5))
    var waiting = dead
    waiting.hasActiveDependents = true
    #expect(waiting.displayState == .waiting)
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

  // MARK: - Remote Copilot event-log presence

  @Test
  func aRemoteCopilotTurnEndReadsAwaitingInput() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: live copilot=assistant.turn_end")
    #expect(reading.presence == .awaitingInput)
    #expect(reading.confidence == .scanned)
  }

  @Test
  func aRemoteCopilotPermissionRequestedReadsAwaitingInput() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: live copilot=permission.requested")
    #expect(reading.presence == .awaitingInput)
    #expect(reading.confidence == .scanned)
  }

  @Test
  func aRemoteCopilotTurnStartReadsBusy() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: live copilot=assistant.turn_start")
    #expect(reading.presence == .busy)
    #expect(reading.confidence == .scanned)
  }

  @Test
  func aRemoteCopilotWithNoEventFallsToHeuristic() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: live copilot=")
    #expect(reading.presence == .idle)
    #expect(reading.confidence == .heuristic)
  }

  @Test
  func aRemoteCopilotWithNoDirFallsToHeuristic() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: live")
    #expect(reading.presence == .idle)
    #expect(reading.confidence == .heuristic)
  }

  @Test
  func anUnreachableRemoteCopilotReadsUnknown() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: false, output: "")
    #expect(reading.presence == .unknown)
  }

  @Test
  func anAbsentRemoteCopilotSessionReadsAbsent() {
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true,
      output: "graphcode-status: absent")
    #expect(reading.presence == .absent)
  }
}
