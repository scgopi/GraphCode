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
