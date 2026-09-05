import Foundation
import Testing

@testable import GraphcodeKit

/// Reading a Copilot session's presence out of the event log it writes.
///
/// Every event name here was read off real logs under `~/.copilot/session-state`, and the
/// orderings the tests assert on are ones a live session actually produced — including the
/// two that would otherwise look like edge cases and are in fact the common path: a
/// `session.usage_checkpoint` landing *after* the turn ended, and a session sitting at the
/// trust-this-folder dialog having written nothing but `session.start`.
@Suite
struct CopilotPresenceTests {
  /// A fixture session directory: a `workspace.yaml` with a name, and a log.
  private func session(named name: String, events: [String], in root: URL) throws -> URL {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    id: \(UUID().uuidString)
    cwd: /tmp/project
    client_name: github/cli
    name: \(name)
    user_named: true
    """.write(
      to: directory.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    let log = events.map { #"{"type": "\#($0)", "data": {}}"# }.joined(separator: "\n")
    try log.write(
      to: directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    return directory
  }

  private func temporaryRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("copilot-presence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test
  func aTurnBoundaryIsReadFromTheEventThatMarksIt() {
    // Copilot's log states turn boundaries outright, where Claude Code's transcript only
    // implies them through a `stop_reason`. Nothing here is inferred.
    #expect(CopilotSessionLog.presence(forEvent: "assistant.turn_start") == .busy)
    #expect(CopilotSessionLog.presence(forEvent: "assistant.turn_end") == .awaitingInput)
    #expect(CopilotSessionLog.presence(forEvent: "tool.execution_start") == .busy)
    #expect(CopilotSessionLog.presence(forEvent: "permission.requested") == .awaitingInput)
    #expect(CopilotSessionLog.presence(forEvent: "session.shutdown") == .absent)
  }

  @Test
  func aSessionParkedAtTheTrustDialogIsNotWorking() {
    // Measured, not reasoned: a Copilot session waiting at "Do you trust the files in this
    // folder?" has written `session.start` and nothing else, for as long as it sits there.
    // Calling that busy would report the exact "looks alive, does nothing" failure this
    // reading exists to expose.
    #expect(CopilotSessionLog.presence(forEvent: "session.start") == nil)
  }

  @Test
  func bookkeepingAfterATurnDoesNotReopenIt() throws {
    // The real ordering: `session.usage_checkpoint` is written *after* `assistant.turn_end`.
    // An unlisted event has to be scanned past, not mapped to something plausible.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(
      named: "graphcode-A",
      events: [
        "user.message", "assistant.turn_start", "assistant.message",
        "tool.execution_start", "tool.execution_complete", "assistant.turn_end",
        "session.usage_checkpoint",
      ], in: root)

    let reading = CopilotSessionLog.lastStateChange(
      inLogAt: directory.appendingPathComponent("events.jsonl"))

    #expect(reading == .awaitingInput)
  }

  @Test
  func aLongToolRunStaysBusyUntilTheTurnActuallyEnds() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(
      named: "graphcode-B",
      events: ["user.message", "assistant.turn_start", "tool.execution_start"], in: root)

    let reading = CopilotSessionLog.lastStateChange(
      inLogAt: directory.appendingPathComponent("events.jsonl"))

    // No hook decays this and no timer expires it: the label is whatever the last event
    // said, which is what keeps a forty-second tool run from reading as a finished loop.
    #expect(reading == .busy)
  }

  @Test
  func aResumeIsNotOverriddenByTheShutdownBehindIt() throws {
    // The real ordering, off a live log: shutdown at 17:30:23, `--resume` at 17:30:26
    // appending to the *same* events.jsonl, nothing mapped since. A reverse scan that
    // only skips unmapped events walks past the resume and reports the shutdown behind
    // it, so a session sitting at its prompt reads `.absent` — FAILED on a running
    // unattended loop, which is what this test exists to keep from coming back.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(
      named: "graphcode-RESUMED",
      events: [
        "session.start", "user.message", "assistant.turn_start", "assistant.turn_end",
        "session.shutdown",
        "session.resume", "session.permissions_changed",
      ], in: root)

    let reading = CopilotSessionLog.lastStateChange(
      inLogAt: directory.appendingPathComponent("events.jsonl"))

    // Nothing since the resume says anything: `presence(of:)` turns this into idle at
    // `.heuristic`, "a live session with nothing happening", never absent.
    #expect(reading == nil)
  }

  @Test
  func workAfterAResumeIsStillRead() throws {
    // The boundary stops the scan; it does not blind it. A resumed session that has
    // started working reads busy off the events written after the resume.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(
      named: "graphcode-RESUMED-BUSY",
      events: [
        "assistant.turn_end", "session.shutdown",
        "session.resume", "user.message", "assistant.turn_start", "tool.execution_start",
      ], in: root)

    let reading = CopilotSessionLog.lastStateChange(
      inLogAt: directory.appendingPathComponent("events.jsonl"))

    #expect(reading == .busy)
  }

  @Test
  func aShutdownWithNoResumeBehindItStillEndsTheSession() throws {
    // The other half: a session that really did shut down must keep reporting absent,
    // or the reading stops being able to say a loop died at all.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(
      named: "graphcode-DEAD",
      events: ["session.start", "user.message", "assistant.turn_end", "session.shutdown"],
      in: root)

    let reading = CopilotSessionLog.lastStateChange(
      inLogAt: directory.appendingPathComponent("events.jsonl"))

    #expect(reading == .absent)
  }

  @Test
  func theRemoteProbeCanSeeAResumeAndBlanksIt() {
    // The remote reader is the same scan expressed as grep + `tail -1`, and it has to
    // make the same two decisions: the boundaries must be in the keep-list for `tail -1`
    // to see them at all, and a boundary in hand must blank the answer rather than be
    // reported as an event.
    let node = LoopNode(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      title: "Sync", loopType: .goalBased, goal: GoalSpec(summary: "main is current"),
      backend: .copilotCLI, state: .running)
    let location = RemoteProjectLocation(host: "box", remotePath: "/home/me/project")
    let script = CopilotSessionLog.remotePresenceInvocation(forNode: node, at: location)
      .joined(separator: " ")

    #expect(script.contains("session\\.resume"))
    #expect(script.contains("session\\.start"))
    // Only as far as the pattern: the whole script rides inside a single-quoted
    // login-shell command, so the empty assignment reaches ssh re-quoted, and
    // matching on that would be a test of the quoter rather than of this.
    #expect(script.contains("case \"$E\" in session.start|session.resume)"))
  }

  @Test
  func anEmptyRemoteEventIsALiveSessionWithNothingToSay() {
    // What the blanked `$E` above arrives as, and the reading it has to produce: the
    // remote twin of `lastStateChange` returning nil.
    let reading = CopilotSessionLog.parseRemotePresence(
      succeeded: true, output: "\(ZmxSessionLauncher.remoteProbeMarker) live copilot=")

    #expect(reading.presence == .idle)
    #expect(reading.confidence == .heuristic)
  }

  @Test
  func theSessionIsFoundByTheNameGraphcodeGaveIt() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    CopilotSessionLog.stateDirectory = root
    defer {
      CopilotSessionLog.stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }
    let wanted = try session(named: "graphcode-WANTED", events: ["assistant.turn_start"], in: root)
    _ = try session(named: "graphcode-OTHER", events: ["assistant.turn_end"], in: root)

    // By last component: `NSTemporaryDirectory()` hands back `/var/…` and the directory
    // enumerator resolves it to `/private/var/…`, so the two spellings of one directory
    // are not `==`.
    #expect(
      CopilotSessionLog.directory(forSessionNamed: "graphcode-WANTED")?.lastPathComponent
        == wanted.lastPathComponent)
    #expect(CopilotSessionLog.directory(forSessionNamed: "graphcode-MISSING") == nil)
  }

  @Test
  func theKeyIsNameNotAnythingEndingInName() throws {
    // `client_name: github/cli` sits two lines above `name:` in every workspace.yaml, and
    // a suffix match would read every Copilot session as belonging to "github/cli".
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try session(named: "graphcode-C", events: [], in: root)

    #expect(CopilotSessionLog.names(directory) == "graphcode-C")
  }

  @Test
  func copilotIsGivenTheNameThatMakesItFindable() {
    // Without `--name` the session-state directory is a bare UUID Copilot chose, and its
    // log — the only presence signal this backend has — belongs to nobody.
    #expect(
      CLISessionBackendKind.copilotCLI.presenceArguments(
        hooksFile: nil, sessionName: "graphcode-D") == ["--name", "graphcode-D"])
    // And the hook file it has no mechanism for changes nothing.
    #expect(
      CLISessionBackendKind.copilotCLI.presenceArguments(
        hooksFile: URL(fileURLWithPath: "/tmp/hooks.json"), sessionName: nil) == [])
  }

  @Test
  func theNameRidesOnARealLaunch() throws {
    let node = LoopNode(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      title: "Ship it", loopType: .goalBased, goal: GoalSpec(summary: "Tests pass"),
      backend: .copilotCLI, state: .running)
    let arguments = try #require(ZmxSessionLauncher.arguments(forNode: node))

    #expect(arguments.contains("--name"))
    #expect(arguments.contains("graphcode-11111111-2222-3333-4444-555555555555"))
  }
}
