import Foundation
import Testing

@testable import GraphcodeKit

/// The summary rail's producer: what a loop is doing, read out of the transcript its own
/// backend already writes.
///
/// Every fixture here is shaped after a real record taken off this machine's
/// `~/.claude/projects`, `~/.codex/sessions` and `~/.copilot/session-state` — keys and
/// nesting included, as `BackendActivityTests` does, because a hand-invented schema tests
/// the parser against nothing.
@Suite
struct SummaryRailTests {
  private func temporaryRoot(_ prefix: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func log(_ lines: [String], named name: String, in root: URL) throws -> URL {
    let url = root.appendingPathComponent(name)
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func line(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  private func stamp(_ seconds: Int) -> String {
    let date = Date(timeIntervalSince1970: 1_777_000_000 + Double(seconds))
    return SummaryBeatBuilder.timestampFormatter.string(from: date)
  }

  // MARK: - Claude Code

  private func claudeUser(_ text: String, at seconds: Int) throws -> String {
    try line([
      "type": "user", "timestamp": stamp(seconds),
      "message": ["role": "user", "content": text],
    ])
  }

  private func claudeToolResult(_ id: String, at seconds: Int) throws -> String {
    try line([
      "type": "user", "timestamp": stamp(seconds),
      "message": [
        "role": "user",
        "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]],
      ],
    ])
  }

  private func claudeAssistant(
    text: String? = nil, tools: [(String, [String: Any])] = [], at seconds: Int,
    isSidechain: Bool = false
  ) throws -> String {
    var content: [[String: Any]] = []
    if let text { content.append(["type": "text", "text": text]) }
    for (name, input) in tools {
      content.append(["type": "tool_use", "name": name, "input": input, "id": "t\(name)"])
    }
    return try line([
      "type": "assistant", "timestamp": stamp(seconds), "isSidechain": isSidechain,
      "message": ["role": "assistant", "content": content],
    ])
  }

  @Test
  func aClaudeNarrationBecomesTheBeatAndItsToolCallsBecomeTheEvidence() throws {
    let root = try temporaryRoot("claude-beats")
    let url = try log(
      [
        try claudeUser("Find why cached tokens double-count", at: 0),
        try claudeAssistant(
          text: "Working out why cached tokens get counted twice.",
          tools: [
            ("Read", ["file_path": "/repo/GraphcodeKit/Sources/Sessions/UsageProbe.swift"]),
            ("Read", ["file_path": "/repo/GraphcodeKit/Sources/Domain/UsageSample.swift"]),
            ("Read", ["file_path": "/repo/CostRollup.swift"]),
          ], at: 10),
      ], named: "session.jsonl", in: root)

    let beats = ClaudeSessionLog.beats(inTranscriptAt: url)

    #expect(beats.count == 1)
    #expect(beats[0].text == "Working out why cached tokens get counted twice")
    #expect(beats[0].kind == .reading)
    #expect(beats[0].evidence == "UsageProbe.swift · 3 files read")
    #expect(beats[0].pass == 1)
  }

  /// The rule the whole feature rests on: a beat is a shift in intent, not a tool call.
  @Test
  func twentyGrepsInARowAreOneBeat() throws {
    let root = try temporaryRoot("claude-greps")
    var lines = [try claudeUser("Trace totalTokens", at: 0)]
    lines.append(
      try claudeAssistant(text: "Tracing totalTokens through the probe.", at: 1))
    for index in 0..<20 {
      lines.append(
        try claudeAssistant(tools: [("Grep", ["pattern": "totalTokens\(index)"])], at: 2 + index))
      lines.append(try claudeToolResult("t\(index)", at: 2 + index))
    }

    let beats = ClaudeSessionLog.beats(
      inTranscriptAt: try log(lines, named: "session.jsonl", in: root))

    #expect(beats.count == 1)
    #expect(beats[0].text == "Tracing totalTokens through the probe")
    #expect(beats[0].evidence == "totalTokens0 · 20 files read")
    // Twenty tool results wearing the user role are not twenty passes.
    #expect(beats[0].pass == 1)
  }

  /// A `Task` sub-agent writes its whole conversation into the same file. Narrating it
  /// would put the sub-agent's work on the parent's rail while the parent's own beat says
  /// "delegating".
  @Test
  func sidechainsDoNotNarrateTheParentLoop() throws {
    let root = try temporaryRoot("claude-sidechain")
    let url = try log(
      [
        try claudeUser("Audit the store", at: 0),
        try claudeAssistant(
          text: "Delegating the sweep.", tools: [("Task", ["description": "sweep sources"])],
          at: 1),
        try claudeAssistant(
          text: "Reading every file in Sources.", at: 2, isSidechain: true),
      ], named: "session.jsonl", in: root)

    let beats = ClaudeSessionLog.beats(inTranscriptAt: url)

    #expect(beats.map(\.text) == ["Delegating the sweep"])
  }

  @Test
  func aPassIsAUserTurn() throws {
    let root = try temporaryRoot("claude-passes")
    let url = try log(
      [
        try claudeUser("first", at: 0),
        try claudeAssistant(text: "Trimmed the system preamble.", at: 1),
        try claudeUser("go again", at: 2),
        try claudeAssistant(text: "Found the double count in aggregate.", at: 3),
      ], named: "session.jsonl", in: root)

    let beats = ClaudeSessionLog.beats(inTranscriptAt: url)

    #expect(beats.map(\.pass) == [1, 2])
    // A past-tense discovery is a finding, which is what earns the green dot.
    #expect(beats[1].kind == .found)
  }

  /// A beat that greps twice and then writes a file is an edit, and naming it after the
  /// grep puts a search string under the word EDITING.
  @Test
  func evidenceNamesACallOfTheBeatsOwnKind() throws {
    let root = try temporaryRoot("claude-evidence")
    let url = try log(
      [
        try claudeUser("fix the double count", at: 0),
        try claudeAssistant(
          text: "Rewriting aggregate to skip cached reads.",
          tools: [
            ("Grep", ["pattern": "totalTokens"]),
            ("Grep", ["pattern": "isBillable"]),
            ("Edit", ["file_path": "/repo/UsageProbe.swift"]),
            ("Edit", ["file_path": "/repo/UsageSample.swift"]),
          ], at: 1),
      ], named: "session.jsonl", in: root)

    let beats = ClaudeSessionLog.beats(inTranscriptAt: url)

    #expect(beats[0].kind == .editing)
    // The first *edit*, and a count of the edits — not of the greps that led to them.
    #expect(beats[0].evidence == "UsageProbe.swift · 2 edits")
  }

  @Test
  func claudeToolPhrasesMatchTheHookScriptsVocabulary() {
    #expect(
      ClaudeSessionLog.phrase(forTool: "Edit", input: ["file_path": "/repo/LoopNode.swift"])
        == "editing LoopNode.swift")
    #expect(
      ClaudeSessionLog.phrase(forTool: "Bash", input: ["command": "make check"])
        == "running make check")
    #expect(
      ClaudeSessionLog.phrase(forTool: "Grep", input: ["pattern": "refreshActivity"])
        == "searching for refreshActivity")
    // A recognised tool whose input isn't the shape expected names itself rather than
    // going quiet — the fallback all three readers share.
    #expect(ClaudeSessionLog.phrase(forTool: "Read", input: [:]) == "using Read")
  }

  @Test
  func theTranscriptIsFoundByTheSessionIDGraphcodeBanked() throws {
    let root = try temporaryRoot("claude-projects")
    let project = root.appendingPathComponent("-repo-worktree", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let sessionID = UUID().uuidString
    _ = try log([try claudeUser("go", at: 0)], named: "\(sessionID).jsonl", in: project)

    let previous = ClaudeSessionLog.projectsDirectory
    ClaudeSessionLog.projectsDirectory = root
    defer { ClaudeSessionLog.projectsDirectory = previous }

    #expect(
      ClaudeSessionLog.transcript(forSessionID: sessionID)?.lastPathComponent
        == "\(sessionID).jsonl")
    #expect(ClaudeSessionLog.transcript(forSessionID: UUID().uuidString) == nil)
  }

  // MARK: - Codex

  @Test
  func codexReasoningHeadersAreAlreadyBeats() throws {
    let root = try temporaryRoot("codex-beats")
    let url = try log(
      [
        try line([
          "type": "event_msg", "timestamp": stamp(0),
          "payload": ["type": "user_message", "message": "look at the probe"],
        ]),
        try line([
          "type": "event_msg", "timestamp": stamp(5),
          "payload": [
            "type": "agent_reasoning",
            "text":
              "**Planning code mode inspection**\n\nI'm preparing to inspect the repo with "
              + "ripgrep to locate where agents are defined, aiming to clarify the source.",
          ],
        ]),
        try line([
          "type": "response_item", "timestamp": stamp(6),
          "payload": [
            "type": "function_call", "name": "shell", "call_id": "c1",
            "arguments": "{\"command\":\"rg totalTokens\"}",
          ],
        ]),
      ], named: "rollout.jsonl", in: root)

    let beats = CodexSessionLog.beats(inRolloutAt: url)

    // The bolded header wins over the paragraph under it: it is already one line of
    // intent, and the paragraph is already three.
    #expect(beats.map(\.text) == ["Planning code mode inspection"])
    #expect(beats[0].kind == .running)
    #expect(beats[0].evidence == "rg totalTokens")
  }

  // MARK: - Copilot

  @Test
  func copilotAssistantMessagesAreTheNarration() throws {
    let root = try temporaryRoot("copilot-beats")
    let url = try log(
      [
        try line(["type": "user.message", "timestamp": stamp(0), "data": ["content": "go"]]),
        try line([
          "type": "assistant.message", "timestamp": stamp(1),
          "data": [
            "content":
              "Running a short shell that starts two concurrent loops. Running it now.",
            "model": "gpt-5-mini",
          ],
        ]),
        try line([
          "type": "tool.execution_start", "timestamp": stamp(2),
          "data": [
            "toolCallId": "call_1", "toolName": "bash",
            "arguments": ["command": "bash -lc 'true'", "description": "Spin two loops"],
          ],
        ]),
      ], named: "events.jsonl", in: root)

    let beats = CopilotSessionLog.beats(inLogAt: url)

    #expect(beats.map(\.text) == ["Running a short shell that starts two concurrent loops"])
    #expect(beats[0].kind == .running)
    // Copilot's own description of the call, which is a better line than the command.
    #expect(beats[0].evidence == "Spin two loops")
  }

  // MARK: - Condensing

  @Test
  func beatsAreOneShortSentenceInTheAgentsOwnWords() {
    #expect(
      SummaryBeatBuilder.condense("Now let me read the design HTML and the rail.")
        == "Let me read the design HTML and the rail")
    #expect(
      SummaryBeatBuilder.condense("**Checking for hidden files**") == "Checking for hidden files")
    // A file name is not a sentence boundary — the extension is the evidence the beat
    // carries.
    #expect(
      SummaryBeatBuilder.condense("Reading UsageProbe.swift now")
        == "Reading UsageProbe.swift now")
    // Agents narrate in markdown and the rail draws plain text. A bold run inside a
    // sentence is not a header, so `boldHeader` never sees it and its asterisks reached
    // the rail — caught on a real transcript, not imagined.
    #expect(
      SummaryBeatBuilder.condense("**No LLM call** — nothing shells out to `claude -p`")
        == "No LLM call — nothing shells out to claude -p")
    // A lone underscore is left alone: an identifier is likelier than emphasis, and the
    // name is the one thing a beat has to get right.
    #expect(
      SummaryBeatBuilder.condense("Tracing total_tokens through the probe")
        == "Tracing total_tokens through the probe")
    // A one-word verdict is a preamble, not a beat: stopping at the full stop put "Clean"
    // alone in the rail and threw away the half that said what was happening. Seen on a
    // real loop.
    #expect(
      SummaryBeatBuilder.condense("Clean. Rebuilding Release and reinstalling.")
        == "Clean. Rebuilding Release and reinstalling")
    // A full opening sentence still stands alone.
    #expect(
      SummaryBeatBuilder.condense("Found the double count. Now fixing it.")
        == "Found the double count")
    #expect(SummaryBeatBuilder.condense("   ") == nil)
    let long = SummaryBeatBuilder.condense(
      "One two three four five six seven eight nine ten eleven twelve")
    #expect(long == "One two three four five six seven eight nine ten…")
  }

  /// Both of these were read straight off a live loop's rail, not imagined.
  @Test
  func aLinksAddressNeverReachesTheRailAndNoWordIsCutInHalf() {
    // The label is the words; the address is not one of them.
    #expect(
      SummaryBeatBuilder.condense(
        "Posted. Live on [@cgopireddy](https://www.threads.com/@cgopireddy)")
        == "Posted. Live on @cgopireddy")
    #expect(
      SummaryBeatBuilder.stripLinks("see [a](x) and [b](y)") == "see a and b")
    // A cut through the middle of a word reads as a rendering fault rather than a summary.
    let cut = SummaryBeatBuilder.truncate(
      "Blocked on login because the browser has no Threads or Instagram session",
      words: 20, characters: 64)
    #expect(cut == "Blocked on login because the browser has no Threads or…")
    // Unless the word itself is longer than the line, where a hard cut is the only answer.
    #expect(
      SummaryBeatBuilder.truncate(String(repeating: "x", count: 40), words: 10, characters: 10)
        == "xxxxxxxxxx…")
  }
}
