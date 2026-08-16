import Foundation
import Testing

@testable import GraphcodeKit

/// The write half of the usage channel — `PresenceHooks.usageScript` summing the
/// session's own transcript into a label `zmx` will actually keep, and
/// `UsageSample.parse` reading that label back. Exercised through a real shell for the
/// same reason `PresenceReportingTests` is: the risk is an expression surviving being
/// Swift, JSON and shell and still not matching what a hook receives.
@Suite
struct UsageReportingTests {
  /// Runs the generated reporter the way Claude Code runs it — `/bin/sh`, the hook
  /// payload on stdin — against a `zmx` that records what it was asked to set.
  private func reportedLabel(payload: String, transcript: String?) throws -> String? {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("graphcode-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var payload = payload
    if let transcript {
      let transcriptFile = directory.appendingPathComponent("transcript.jsonl")
      try transcript.write(to: transcriptFile, atomically: true, encoding: .utf8)
      payload = payload.replacingOccurrences(of: "TRANSCRIPT", with: transcriptFile.path)
    }

    let recording = directory.appendingPathComponent("set.txt")
    let fakeZmx = directory.appendingPathComponent("zmx")
    try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(recording.path)'\n"
      .write(to: fakeZmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

    let script = directory.appendingPathComponent("usage.sh")
    try PresenceHooks.usageScript(zmxPath: fakeZmx.path)
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

    // A `Stop` hook exiting non-zero blocks the very stop it was reporting.
    #expect(process.terminationStatus == 0)
    guard let recorded = try? String(contentsOf: recording, encoding: .utf8),
      let line = recorded.split(separator: "\n").last,
      let label = line.split(separator: " ").last.map(String.init)
    else { return nil }
    return label
  }

  private let stopPayload = """
    {"session_id":"a","hook_event_name":"Stop","transcript_path":"TRANSCRIPT"}
    """

  @Test
  func theTranscriptsSpendBecomesALabelTheReaderUnderstands() throws {
    // Two assistant turns; cache creation and cache reads count as input — a budget is
    // spent by what the API metered, not just the fresh bytes.
    let transcript = """
      {"type":"user","message":{"role":"user","content":"hi"}}
      {"type":"assistant","message":{"usage":{"input_tokens":100,\
      "cache_creation_input_tokens":2000,"cache_read_input_tokens":30000,\
      "output_tokens":40}}}
      {"type":"assistant","message":{"usage":{"input_tokens":10,\
      "cache_read_input_tokens":32000,"output_tokens":60}}}
      """
    let label = try reportedLabel(payload: stopPayload, transcript: transcript)
    #expect(label == "usage=input.64110_output.100")

    // Both halves of the channel: a label the reader can't undo is the same bug as no
    // label at all.
    let sample = UsageSample.parse("input.64110_output.100")
    #expect(sample?.inputTokens == 64110)
    #expect(sample?.outputTokens == 100)
    #expect(sample?.totalTokens == 64210)
  }

  @Test
  func aMultiBlockTurnCountsItsMessageOnceNotPerRecord() throws {
    // Claude Code writes one JSONL record per content block, each repeating the same
    // message-level usage — the double-count a budget-capped review loop caught in the
    // first version of this script (naive line-sum ran ~2× the metered spend).
    let transcript = """
      {"type":"assistant","message":{"id":"msg_01AAA","usage":{"input_tokens":100,\
      "output_tokens":40}}}
      {"type":"assistant","message":{"id":"msg_01AAA","usage":{"input_tokens":100,\
      "output_tokens":40}}}
      {"type":"assistant","message":{"id":"msg_01AAA","usage":{"input_tokens":100,\
      "output_tokens":40}}}
      {"type":"assistant","message":{"id":"msg_01BBB","usage":{"input_tokens":7,\
      "output_tokens":3}}}
      """
    let label = try reportedLabel(payload: stopPayload, transcript: transcript)
    #expect(label == "usage=input.107_output.43")
  }

  @Test
  func aMissingTranscriptReportsNothingAndStillExitsZero() throws {
    let payload = """
      {"session_id":"a","hook_event_name":"Stop","transcript_path":"/nonexistent/t.jsonl"}
      """
    #expect(try reportedLabel(payload: payload, transcript: nil) == nil)
  }

  @Test
  func aTranscriptWithNoUsageReportsNothing() throws {
    // Zero would be a claim; silence is the honest reading of a transcript that has
    // no metered turns yet.
    let transcript = """
      {"type":"user","message":{"role":"user","content":"hi"}}
      """
    #expect(try reportedLabel(payload: stopPayload, transcript: transcript) == nil)
  }

  @Test
  func theDottedFormParsesAndTheDocumentedEqualsFormStillDoes() {
    // The dotted form is built from exactly the bytes a zmx label value may hold.
    #expect(UsageSample.parse("input.10_output.20")?.totalTokens == 30)
    #expect(UsageSample.parse("input.10_output.20_cost.0.0042")?.costUSD == 0.0042)
    #expect(UsageSample.parse("inputTokens.10")?.inputTokens == 10)
    // Unknown keys are ignored; garbage stays nil, never a confident zero.
    #expect(UsageSample.parse("something.9_output.4")?.outputTokens == 4)
    #expect(UsageSample.parse("input.notanumber") == nil)
    // The original space/comma k=v shape keeps working for the remote path.
    #expect(UsageSample.parse("inputTokens=10,outputTokens=20")?.totalTokens == 30)
  }

  @Test
  func turnEndAndSessionEndRunTheReporterOtherEventsDoNot() throws {
    let json = try #require(
      PresenceHooks.json(forBackend: .claudeCode, zmxPath: "/usr/local/bin/zmx"))
    let settings = try #require(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let hooks = try #require(settings["hooks"] as? [String: Any])
    func bodies(_ event: String) throws -> [String] {
      let matchers = try #require(hooks[event] as? [[String: Any]])
      let entries = try #require(matchers.first?["hooks"] as? [[String: Any]])
      return entries.compactMap { $0["command"] as? String }
    }
    #expect(try bodies("Stop").contains { $0.contains("usage.sh") })
    #expect(try bodies("SessionEnd").contains { $0.contains("usage.sh") })
    // Per tool call would price a whole-transcript read wrong.
    #expect(try !bodies("PreToolUse").contains { $0.contains("usage.sh") })
  }

  @Test
  func aRemoteSessionIsHandedTheReporterToo() throws {
    let fragment = try #require(PresenceHooks.remoteWriteFragment())
    #expect(fragment.contains("$HOME/.graphcode/hooks/usage.sh"))
  }
}
