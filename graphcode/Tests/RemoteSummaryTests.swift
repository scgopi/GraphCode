import Foundation
import Testing

@testable import GraphcodeKit

/// The rail over ssh: a remote loop's transcript is on the other machine, and the beats
/// have to come back over the same connection everything else about it does.
///
/// Asserted as a script and a parse rather than against a host, the way
/// `RemoteLoopSurvivalTests` asserts the ensure dial: what can be got wrong here is the
/// shell fragment and the framing, and both are values.
@Suite
struct RemoteSummaryTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")

  private func node(_ backend: CLISessionBackendKind) -> LoopNode {
    LoopNode(title: "Usage", loopType: .goalBased, backend: backend)
  }

  private func remoteCommand(_ invocation: [String]) -> String {
    invocation.last ?? ""
  }

  @Test
  func theProbeIsOneMultiplexedDialThatFindsTheTranscriptItself() {
    let invocation = ClaudeSessionLog.remoteSummaryInvocation(
      forNode: node(.claudeCode), at: location, since: nil)

    // The same multiplexed connection every other remote reading rides.
    #expect(invocation.first == "/usr/bin/ssh")
    #expect(invocation.contains("ControlMaster=auto"))
    #expect(invocation.contains("-p"))
    #expect(invocation.contains("2222"))
    #expect(invocation.contains("dev@build-box"))

    let script = remoteCommand(invocation)
    // The id the host banks for `--resume` is the id the transcript is named after, so
    // the lookup is the local rule in `sh` rather than a second rule.
    #expect(script.contains(".graphcode/sessions"))
    #expect(script.contains(".claude/projects"))
    #expect(script.contains(RemoteTranscriptProbe.marker))
    // Tool results are most of a transcript's bytes and make no beats — they never travel.
    #expect(script.contains("grep -av toolUseResult"))
    #expect(script.contains("tail -c 262144"))
  }

  /// A transcript that has not moved answers in one word, and that is what makes a poll
  /// over a network affordable at all.
  @Test
  func aStampWeAlreadyHaveIsSentBackSoNothingShips() {
    let script = remoteCommand(
      ClaudeSessionLog.remoteSummaryInvocation(
        forNode: node(.claudeCode), at: location, since: "1786700000"))

    #expect(script.contains("1786700000"))
    #expect(script.contains("unchanged"))
    // Both spellings of stat: a loop's host is a Linux box or a Mac, and this runs on
    // whichever it is.
    #expect(script.contains("stat -c %Y"))
    #expect(script.contains("stat -f %m"))
  }

  @Test
  func copilotAndCodexBringBackTheirOwnFiles() {
    let copilot = remoteCommand(
      CopilotSessionLog.remoteSummaryInvocation(
        forNode: node(.copilotCLI), at: location, since: nil))
    #expect(copilot.contains(".copilot/session-state"))
    #expect(copilot.contains("workspace.yaml"))
    // A keep-list, spelled as the grep sees it: Copilot's log carries whole tool outputs
    // in a type of their own, and they never travel.
    #expect(copilot.contains(#"assistant\.message"#))
    #expect(copilot.contains(#"assistant\.turn_end"#))
    #expect(copilot.contains("tool.execution_complete") == false)

    let codex = remoteCommand(
      CodexSessionLog.remoteSummaryInvocation(
        forNode: node(.codex), at: location, workingDirectory: "/home/dev/widget", since: nil))
    #expect(codex.contains(".codex/sessions"))
    // Codex has no `--name`; the directory the session opened in is the only handle.
    #expect(codex.contains("/home/dev/widget"))
    #expect(codex.contains("function_call_output"))
  }

  // MARK: - Framing

  private func reply(_ lines: [String]) -> String {
    // As it arrives: the remote login shell's own chatter first, and a carriage return on
    // every line because the probe comes back over a PTY.
    (["Welcome to build-box", "(reverse-i-search)"] + lines).joined(separator: "\r\n")
  }

  @Test
  func theMarkerIsWhatIsRead() {
    let record = #"{"type":"assistant","timestamp":"2026-08-13T22:39:28.418Z"}"#
    let parsed = RemoteTranscriptProbe.parse(
      succeeded: true, output: reply(["graphcode-summary: lines 1786700123", record]))

    #expect(parsed == .lines(stamp: "1786700123", lines: [Data(record.utf8)]))

    #expect(
      RemoteTranscriptProbe.parse(
        succeeded: true, output: reply(["graphcode-summary: unchanged"])) == .unchanged)
    #expect(
      RemoteTranscriptProbe.parse(
        succeeded: true, output: reply(["graphcode-summary: nothing"])) == .nothing)
    // ssh itself failing says nothing about the session, and a shell that printed no
    // marker never ran the script.
    #expect(RemoteTranscriptProbe.parse(succeeded: false, output: "") == .nothing)
    #expect(
      RemoteTranscriptProbe.parse(succeeded: true, output: reply(["some rc noise"]))
        == .nothing)
  }

  /// The whole point of the round trip: records in, beats out, through the same reader the
  /// local path uses.
  @Test
  func remoteRecordsBecomeTheSameBeatsLocalOnesDo() throws {
    let stamp = "2026-08-13T22:39:28.418Z"
    let user = #"{"type":"user","timestamp":"\#(stamp)","message":{"role":"user","content":"go"}}"#
    let assistant =
      #"{"type":"assistant","timestamp":"\#(stamp)","message":{"role":"assistant","#
      + #""stop_reason":"end_turn","content":[{"type":"text","text":"Shipped the beta."}]}}"#

    guard
      case .lines(_, let lines) = RemoteTranscriptProbe.parse(
        succeeded: true, output: reply(["graphcode-summary: lines 1786700123", user, assistant]))
    else {
      Issue.record("the probe did not frame a payload")
      return
    }

    var builder = ClaudeSessionLog.builder(forLines: lines)
    let beats = builder.beats()

    #expect(beats.map(\.text) == ["Shipped the beta"])
    #expect(beats.first?.endsTurn == true)
    #expect(builder.userTurns().count == 1)
  }
}
