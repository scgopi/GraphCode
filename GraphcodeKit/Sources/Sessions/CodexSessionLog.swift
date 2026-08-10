import Foundation

/// Codex's activity, read out of the rollout file it already writes.
///
/// Codex reports one lifecycle edge and no tool calls: `notify` fires on
/// `agent-turn-complete` (`PresenceHooks.codexNotifyOverride`), which is enough for
/// presence — see `ZmxSessionLauncher.codexPresence` — and says nothing about what the
/// turn is *doing*. So activity comes from the other end, the way `CopilotSessionLog`
/// takes Copilot's: every session appends
/// `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-<stamp>-<uuid>.jsonl`, and each tool call
/// is a record in it.
///
/// This is the "scanned" tier of docs/04-cli-backends.md#presence — a reading the backend
/// did not volunteer, taken from outside — and `LoopNode.activity` carries no confidence
/// of its own, so nothing here claims the agent said it.
public enum CodexSessionLog {
  /// Where Codex keeps its rollouts, one directory per day. A `var` only so tests can
  /// point it at a fixture; nothing in the app writes it.
  public static var sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex/sessions", isDirectory: true)

  /// How much of the tail is enough to find the last tool call. A rollout carries whole
  /// model turns including reasoning, so the records are far larger than Copilot's events
  /// and the window has to be correspondingly wider.
  static let tailBytes = 256 * 1024

  /// How many recent rollouts to consider before giving up on matching one to a node.
  ///
  /// The directory grows one file per session forever, and the answer is always among the
  /// newest — a node's session is either running now or it is not the one being asked
  /// about. Bounded so a machine with a year of Codex history costs the same as a fresh
  /// one on every poll.
  static let recentRolloutLimit = 40

  /// Every rollout file, newest first, capped at `recentRolloutLimit`.
  static func recentRollouts() -> [URL] {
    let manager = FileManager.default
    guard
      let walker = manager.enumerator(
        at: sessionsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }
    let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    return
      files
      .map { url -> (URL, Date) in
        let date =
          (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        return (url, date)
      }
      .sorted { $0.1 > $1.1 }
      .prefix(recentRolloutLimit)
      .map(\.0)
  }

  /// The directory a rollout was started in, off its `session_meta` record.
  ///
  /// Always the first line, so only the first line is read — the alternative is parsing
  /// megabytes of transcript to answer a question the header already answers.
  static func workingDirectory(ofRolloutAt url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
    guard let firstLine = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
      let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)),
      let record = object as? [String: Any],
      record["type"] as? String == "session_meta",
      let payload = record["payload"] as? [String: Any]
    else { return nil }
    return payload["cwd"] as? String
  }

  /// The rollout belonging to a node, matched on the directory its session opened in.
  ///
  /// Codex has no equivalent of Copilot's `--name`, so the working directory is the only
  /// handle graphcode has on which rollout is whose. That is exact for a node bound to
  /// its own worktree and ambiguous for several loops sharing one project folder, where
  /// newest-first resolves it the same way `CopilotSessionLog.directory` does — the one
  /// being written to now is the one that matters.
  ///
  /// Paths are compared normalized because `session_meta` records the directory as Codex
  /// resolved it, and a node's worktree path can reach the same place by another spelling
  /// — the same mismatch that put a whole repository in the worktree sweeper.
  static func rollout(forWorkingDirectory directory: String) -> URL? {
    let wanted = RemoteProjectLocation.normalizedPath(directory)
    return recentRollouts().first { url in
      guard let cwd = workingDirectory(ofRolloutAt: url) else { return false }
      return RemoteProjectLocation.normalizedPath(cwd) == wanted
    }
  }

  /// What one tool-call record is doing, in the same voice as the other two backends.
  static func phrase(forRecord payload: [String: Any]) -> String? {
    func trimmed(_ value: Any?) -> String? {
      guard let text = value as? String else { return nil }
      let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return clean.isEmpty ? nil : clean
    }
    switch payload["type"] as? String {
    case "function_call":
      guard let name = payload["name"] as? String else { return nil }
      // `arguments` is a JSON *string*, not an object — the wire shape of a tool call.
      let decoded = trimmed(payload["arguments"])
        .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
      let arguments = decoded as? [String: Any] ?? [:]
      let specific: String?
      switch name {
      case "shell", "shell_command", "local_shell", "container.exec":
        // `command` is a string in some Codex versions and an argv array in others.
        let command =
          trimmed(arguments["command"])
          ?? trimmed(
            (arguments["command"] as? [Any])?
              .compactMap { $0 as? String }
              .joined(separator: " "))
        specific = command.map { "running \($0)" }
      case "read_file", "view":
        specific = trimmed(arguments["path"]).map { "reading \(leaf($0))" }
      case "update_plan":
        specific = "planning"
      default:
        specific = nil
      }
      // As in `CopilotSessionLog.phrase`: a recognised tool whose arguments aren't the
      // shape expected names itself rather than going quiet.
      return specific ?? "using \(name)"
    case "custom_tool_call":
      guard let name = payload["name"] as? String else { return nil }
      guard name == "apply_patch" else { return "using \(name)" }
      // The patch envelope names its own files; the first is the one to report.
      guard let input = trimmed(payload["input"]) else { return "editing files" }
      return patchedFile(in: input).map { "editing \($0)" } ?? "editing files"
    case "web_search_call":
      let action = payload["action"] as? [String: Any] ?? [:]
      return trimmed(action["query"]).map { "searching the web for \($0)" }
        ?? "searching the web"
    default:
      return nil
    }
  }

  /// The first path named by an `apply_patch` envelope, whichever verb introduces it.
  static func patchedFile(in patch: String) -> String? {
    let verbs = ["*** Update File: ", "*** Add File: ", "*** Delete File: "]
    for line in patch.split(separator: "\n") {
      for verb in verbs where line.hasPrefix(verb) {
        return leaf(String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces))
      }
    }
    return nil
  }

  static func leaf(_ path: String) -> String {
    String(path.split(separator: "/").last ?? Substring(path))
  }

  /// The tool call this rollout is inside right now, or `nil` when it is between calls.
  ///
  /// Outputs are what end a call: `function_call_output` and `custom_tool_call_output`
  /// carry the `call_id` of the call they answer, so walking backwards and remembering
  /// them is what distinguishes a call still running from one already answered. Without
  /// that a finished command would sit on the card through the whole of the next think.
  static func lastActivity(inRolloutAt url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return nil }
    let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
    try? handle.seek(toOffset: start)
    guard let data = try? handle.readToEnd() else { return nil }
    var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }

    var answered = Set<String>()
    for line in lines.reversed() {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
        let record = object as? [String: Any],
        let payload = record["payload"] as? [String: Any]
      else { continue }
      let type = payload["type"] as? String
      let callID = payload["call_id"] as? String
      if type == "function_call_output" || type == "custom_tool_call_output" {
        if let callID { answered.insert(callID) }
        continue
      }
      if let callID, answered.contains(callID) { continue }
      if let phrase = phrase(forRecord: payload) {
        return ZmxSessionLauncher.condensedActivity(phrase)
      }
    }
    return nil
  }

  /// What this node's Codex session is doing, or `nil` when nothing says.
  ///
  /// Local only, for the reason `CopilotSessionLog.activity` is: the rollout lives on
  /// whichever machine ran Codex, and carrying a JSON record back through a remote shell
  /// is a larger change than this. Remote Codex activity stays `nil`, which is what every
  /// Codex node reported before this.
  public static func activity(of node: LoopNode, projectPath: String? = nil) async -> String? {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    guard ZmxLocator.isInstalled, await ZmxSessionLauncher.sessionExists(node),
      let directory = ZmxSessionLauncher.workingDirectory(
        forNode: node, projectPath: projectPath),
      let rollout = rollout(forWorkingDirectory: directory)
    else { return nil }
    return lastActivity(inRolloutAt: rollout)
  }
}
