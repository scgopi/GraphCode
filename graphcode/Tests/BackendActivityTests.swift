import Foundation
import Testing

@testable import GraphcodeKit

/// What Copilot and Codex loops say they are doing, read out of the logs they already
/// write. Claude Code reports its own activity through a hook it installs; neither of
/// these has one, so both are scanned from outside — the same arrangement
/// `CopilotSessionLog.presence` already uses for presence.
///
/// Every fixture record here is shaped after a real one taken off this machine's
/// `~/.copilot/session-state` and `~/.codex/sessions`, keys and nesting included, because
/// a hand-invented schema would test the parser against nothing.
@Suite
struct BackendActivityTests {
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

  /// Fixtures are serialized rather than hand-written: `arguments` is a JSON string
  /// *inside* a JSON string, and hand-escaping that wrong silently tests the
  /// unparseable-arguments path instead of the one named in the test.
  private func line(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }

  private func copilotStart(_ id: String, _ tool: String, _ arguments: [String: Any]) throws
    -> String
  {
    try line([
      "type": "tool.execution_start",
      "data": ["toolCallId": id, "toolName": tool, "arguments": arguments],
    ])
  }

  private func copilotComplete(_ id: String) throws -> String {
    try line(["type": "tool.execution_complete", "data": ["toolCallId": id]])
  }

  private func codexCall(_ id: String, _ name: String, _ arguments: [String: Any]) throws -> String
  {
    let encoded = String(
      decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    return try line([
      "type": "response_item",
      "payload": [
        "type": "function_call", "name": name, "arguments": encoded, "call_id": id,
      ],
    ])
  }

  private func codexOutput(_ id: String) throws -> String {
    try line([
      "type": "response_item",
      "payload": ["type": "function_call_output", "call_id": id, "output": "Exit code: 0"],
    ])
  }

  // MARK: - Copilot

  @Test
  func copilotToolCallsBecomeTheSentenceOnTheCard() {
    #expect(
      CopilotSessionLog.phrase(forTool: "view", arguments: ["path": "/tmp/repo/GraphStore.swift"])
        == "reading GraphStore.swift")
    #expect(
      CopilotSessionLog.phrase(forTool: "grep", arguments: ["pattern": "refreshActivity"])
        == "searching for refreshActivity")
    // Copilot writes its own one-line description of a shell call, which is a better
    // sentence than anything assembled from the command here.
    #expect(
      CopilotSessionLog.phrase(
        forTool: "bash",
        arguments: ["command": "ls -la", "description": "List the repository root"])
        == "running List the repository root")
    #expect(
      CopilotSessionLog.phrase(forTool: "bash", arguments: ["command": "make check"])
        == "running make check")
    // The tool vocabulary is the backend's to change; an unknown one is still worth naming.
    #expect(CopilotSessionLog.phrase(forTool: "fetch", arguments: [:]) == "using fetch")
  }

  @Test
  func copilotReportsTheCallItIsStillInside() throws {
    let root = try temporaryRoot("copilot-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try log(
      [
        try line(["type": "assistant.turn_start", "data": [:]]),
        try copilotStart("call_1", "bash", ["command": "make check"]),
      ], named: "events.jsonl", in: root)

    #expect(CopilotSessionLog.lastActivity(inLogAt: url) == "running make check")
  }

  @Test
  func copilotDropsACallThatHasAlreadyCompleted() throws {
    let root = try temporaryRoot("copilot-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    // The completion carries the same `toolCallId` as its start. Without matching them the
    // finished command would sit on the card through the whole of the next think — the
    // stale label this feature exists to remove.
    let url = try log(
      [
        try copilotStart("call_1", "bash", ["command": "make check"]),
        try copilotComplete("call_1"),
      ], named: "events.jsonl", in: root)

    #expect(CopilotSessionLog.lastActivity(inLogAt: url) == nil)
  }

  @Test
  func copilotReportsTheSecondCallWhileTheFirstIsDone() throws {
    let root = try temporaryRoot("copilot-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try log(
      [
        try copilotStart("call_1", "bash", ["command": "make check"]),
        try copilotComplete("call_1"),
        try copilotStart("call_2", "view", ["path": "/tmp/a/GraphStore.swift"]),
      ], named: "events.jsonl", in: root)

    #expect(CopilotSessionLog.lastActivity(inLogAt: url) == "reading GraphStore.swift")
  }

  @Test
  func copilotIsDoingNothingOnceTheTurnHasEnded() throws {
    let root = try temporaryRoot("copilot-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    // `assistant.turn_end` after an unmatched start: a session killed mid-call leaves its
    // log ending exactly this way, and a card claiming work would outlive the work.
    let url = try log(
      [
        try copilotStart("call_1", "bash", ["command": "make check"]),
        try line(["type": "assistant.turn_end", "data": [:]]),
      ], named: "events.jsonl", in: root)

    #expect(CopilotSessionLog.lastActivity(inLogAt: url) == nil)
  }

  // MARK: - Codex

  @Test
  func codexToolCallsBecomeTheSentenceOnTheCard() {
    // `arguments` arrives as a JSON *string*, which is the wire shape of a tool call.
    #expect(
      CodexSessionLog.phrase(forRecord: [
        "type": "function_call", "name": "shell_command",
        "arguments": #"{"command":"ls","workdir":"/tmp/repo"}"#,
      ]) == "running ls")
    #expect(
      CodexSessionLog.phrase(forRecord: [
        "type": "web_search_call", "action": ["type": "search", "query": "SwiftTerm usage"],
      ]) == "searching the web for SwiftTerm usage")
    #expect(
      CodexSessionLog.phrase(forRecord: [
        "type": "custom_tool_call", "name": "apply_patch",
        "input": "*** Begin Patch\n*** Update File: /tmp/repo/TerminalSession.swift\n@@\n-a\n+b\n",
      ]) == "editing TerminalSession.swift")
    #expect(
      CodexSessionLog.phrase(forRecord: ["type": "function_call", "name": "update_plan"])
        == "planning")
    #expect(
      CodexSessionLog.phrase(forRecord: ["type": "function_call", "name": "browser_open"])
        == "using browser_open")
    // Reasoning and messages are not tool calls and must not be mistaken for activity.
    #expect(CodexSessionLog.phrase(forRecord: ["type": "message", "role": "assistant"]) == nil)
  }

  @Test
  func codexAcceptsAnArgvArrayAsWellAsAString() {
    // Older Codex builds pass `command` as an argv array rather than a string.
    #expect(
      CodexSessionLog.phrase(forRecord: [
        "type": "function_call", "name": "shell",
        "arguments": #"{"command":["bash","-lc","make check"]}"#,
      ]) == "running bash -lc make check")
  }

  @Test
  func codexReportsTheCallItIsStillInside() throws {
    let root = try temporaryRoot("codex-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try log(
      [try codexCall("call_1", "shell_command", ["command": "make check"])],
      named: "rollout.jsonl", in: root)

    #expect(CodexSessionLog.lastActivity(inRolloutAt: url) == "running make check")
  }

  @Test
  func codexDropsACallItsOutputHasAlreadyAnswered() throws {
    let root = try temporaryRoot("codex-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try log(
      [
        try codexCall("call_1", "shell_command", ["command": "make check"]),
        try codexOutput("call_1"),
      ], named: "rollout.jsonl", in: root)

    #expect(CodexSessionLog.lastActivity(inRolloutAt: url) == nil)
  }

  // MARK: - Bounds

  /// Found by running the parser over a real rollout rather than a fixture: Codex writes
  /// whole `cat > file <<'EOF'` heredocs as one `command`, hundreds of characters across
  /// dozens of lines. Claude Code's hook caps and flattens before writing its label, so
  /// only the scanned backends can produce this — and a card is one line.
  @Test
  func aHeredocCommandIsFlattenedAndBounded() throws {
    let root = try temporaryRoot("codex-activity")
    defer { try? FileManager.default.removeItem(at: root) }
    // Built rather than hand-escaped: `arguments` is a JSON string *inside* a JSON
    // string, and getting that wrong silently tests the unparseable-arguments path.
    let heredoc = "cat > Package.swift <<'EOF'\nimport PackageDescription\n\nlet package = 1\nEOF"
    let arguments = String(
      decoding: try JSONSerialization.data(withJSONObject: ["command": heredoc]), as: UTF8.self)
    let record: [String: Any] = [
      "type": "response_item",
      "payload": [
        "type": "function_call", "name": "shell_command",
        "arguments": arguments, "call_id": "call_1",
      ],
    ]
    let line = String(
      decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    let url = try log([line], named: "rollout.jsonl", in: root)

    let activity = try #require(CodexSessionLog.lastActivity(inRolloutAt: url))
    #expect(!activity.contains("\n"))
    #expect(activity.count <= 80)
    #expect(activity.hasPrefix("running cat > Package.swift"))
  }

  @Test
  func codexFindsTheRolloutByTheDirectoryItOpenedIn() throws {
    let root = try temporaryRoot("codex-sessions")
    defer { try? FileManager.default.removeItem(at: root) }
    let day = root.appendingPathComponent("2026/08/09", isDirectory: true)
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    _ = try log(
      [
        try line(["type": "session_meta", "payload": ["session_id": "a", "cwd": "/tmp/other"]]),
        try codexCall("x", "shell_command", ["command": "wrong"]),
      ], named: "rollout-a.jsonl", in: day)
    _ = try log(
      [
        try line(["type": "session_meta", "payload": ["session_id": "b", "cwd": "/tmp/wanted"]]),
        try codexCall("y", "shell_command", ["command": "right"]),
      ], named: "rollout-b.jsonl", in: day)

    let previous = CodexSessionLog.sessionsDirectory
    CodexSessionLog.sessionsDirectory = root
    defer { CodexSessionLog.sessionsDirectory = previous }

    // Trailing slash on purpose: `session_meta` records the directory as Codex resolved
    // it, and a node's worktree path can reach the same place by another spelling.
    let found = CodexSessionLog.rollout(forWorkingDirectory: "/tmp/wanted/")
    #expect(found?.lastPathComponent == "rollout-b.jsonl")
    #expect(CodexSessionLog.rollout(forWorkingDirectory: "/tmp/absent") == nil)
  }
}
