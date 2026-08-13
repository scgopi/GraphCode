import Foundation

/// Claude Code's narration, read out of the transcript it already writes.
///
/// Claude Code is the one backend that reports its activity *itself*, through the
/// `PreToolUse` hook `PresenceHooks` installs — which is why it never needed a log reader
/// the way Copilot and Codex did. That hook reports one phrase at a time into a label
/// store, though, and a summary rail needs the sentence *around* the phrase: what the
/// session said it was about to do, before it did it.
///
/// So this is the third reader in the shape of the other two. Every session appends
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, one record per message, and the
/// assistant's own text blocks are the narration. The session id is the one graphcode
/// already banks for `--resume` (`SessionIDStore`), so the file is found without guessing.
///
/// This is the "scanned" tier of docs/04-cli-backends.md#presence, same as the others: a
/// reading taken from outside, carrying no claim that the agent reported it.
public enum ClaudeSessionLog {
  /// Where Claude Code keeps one directory per project. A `var` only so tests can point it
  /// at a fixture; nothing in the app writes it.
  public static var projectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects", isDirectory: true)

  /// The transcript for a session id, found by name across the project directories.
  ///
  /// Searched rather than derived. The directory name is the working directory with its
  /// separators flattened, and reproducing that encoding here would be a second copy of a
  /// rule Claude Code owns and can change — while the file name is exactly the session id,
  /// which graphcode banked itself. One shallow pass over a directory of directories is
  /// cheaper than being wrong.
  public static func transcript(forSessionID sessionID: String) -> URL? {
    let manager = FileManager.default
    guard
      let projects = try? manager.contentsOfDirectory(
        at: projectsDirectory, includingPropertiesForKeys: nil)
    else { return nil }
    let name = "\(sessionID).jsonl"
    for project in projects {
      let candidate = project.appendingPathComponent(name)
      if manager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  /// What one `tool_use` block is doing, in the same voice as the other two readers.
  ///
  /// Deliberately a second copy of `PresenceHooks.activityScript`'s `case` rather than a
  /// shared table: that one is a `sed` pipeline that has to run inside a hook on a machine
  /// graphcode may not be on, and this one runs in-process over a parsed record. Sharing
  /// them would mean generating shell from Swift or parsing JSON in `sh`. They are checked
  /// against each other in `SummaryRailTests`.
  public static func phrase(forTool name: String, input: [String: Any]) -> String? {
    func text(_ key: String) -> String? {
      guard let raw = input[key] as? String else { return nil }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    func leaf(_ key: String) -> String? {
      text(key).map { String($0.split(separator: "/").last ?? Substring($0)) }
    }
    let specific: String?
    switch name {
    case "Edit", "Write", "MultiEdit", "NotebookEdit":
      specific = leaf("file_path").map { "editing \($0)" }
    case "Read":
      specific = leaf("file_path").map { "reading \($0)" }
    case "Bash", "BashOutput":
      specific = (text("description") ?? text("command")).map { "running \($0)" }
    case "Grep":
      specific = text("pattern").map { "searching for \($0)" }
    case "Glob":
      specific = text("pattern").map { "looking for \($0)" }
    case "WebSearch":
      specific = text("query").map { "searching the web for \($0)" }
    case "WebFetch":
      specific = text("url").map { url in
        let host = url.split(separator: "/").dropFirst(2).first.map(String.init) ?? url
        return "reading \(host)"
      }
    case "Task", "Agent":
      specific = text("description").map { "delegating \($0)" }
    case "Skill":
      specific = text("skill").map { "running the \($0) skill" }
    case "TodoWrite", "TaskCreate", "TaskUpdate":
      specific = "planning"
    default:
      specific =
        name.hasPrefix("mcp__")
        ? "using \(name.split(separator: "_").last.map(String.init) ?? name)" : nil
    }
    // A recognised tool whose input isn't the shape expected names itself rather than
    // going quiet — the same fallback the other two readers make.
    return specific ?? "using \(name)"
  }

  /// Every beat in a transcript's tail, oldest first.
  ///
  /// **Sidechains are skipped.** A `Task`/`Agent` sub-agent writes its whole conversation
  /// into the same file marked `isSidechain`, and folding that in would narrate the
  /// sub-agent's work as if it were the loop's — five beats deep in a file the human never
  /// asked about, while the loop's own beat says "delegating".
  public static func beats(inTranscriptAt url: URL) -> [SummaryBeat] {
    var builder = builder(inTranscriptAt: url)
    return builder.beats()
  }

  /// The same read, as the reading the store merges — beats, the turns that bound them,
  /// and where the metric got to.
  static func reading(inTranscriptAt url: URL, metricSamples: [MetricSample]) -> SummaryReading {
    var builder = builder(inTranscriptAt: url)
    return SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), metricSamples: metricSamples)
  }

  private static func builder(inTranscriptAt url: URL) -> SummaryBeatBuilder {
    var builder = SummaryBeatBuilder()
    for line in SummaryBeatBuilder.tailLines(of: url) {
      guard let object = try? JSONSerialization.jsonObject(with: line),
        let record = object as? [String: Any],
        record["isSidechain"] as? Bool != true,
        let type = record["type"] as? String
      else { continue }
      let at = SummaryBeatBuilder.date(fromTimestamp: record["timestamp"]) ?? Date()
      let message = record["message"] as? [String: Any] ?? [:]
      switch type {
      case "user":
        guard isUserTurn(message) else { continue }
        builder.noteUserTurn(at: at)
      case "assistant":
        for block in message["content"] as? [[String: Any]] ?? [] {
          switch block["type"] as? String {
          case "text":
            builder.noteNarration(block["text"] as? String ?? "", at: at)
          case "tool_use":
            guard let name = block["name"] as? String,
              let phrase = phrase(
                forTool: name, input: block["input"] as? [String: Any] ?? [:])
            else { continue }
            builder.noteTool(phrase, at: at)
          default:
            continue
          }
        }
      default:
        continue
      }
    }
    return builder
  }

  /// Whether a `user` record is a turn or a tool result wearing the user role.
  ///
  /// Every tool result comes back as a `user` message whose content is an array of
  /// `tool_result` blocks, so counting those as passes would make a pass out of every
  /// `grep`. A turn is a plain string, or an array carrying real text.
  static func isUserTurn(_ message: [String: Any]) -> Bool {
    if let text = message["content"] as? String {
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard let blocks = message["content"] as? [[String: Any]] else { return false }
    return blocks.contains { block in
      guard block["type"] as? String == "text" else { return false }
      let text = block["text"] as? String ?? ""
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// What this node's Claude Code session has been doing, or `nil` when nothing says.
  ///
  /// Local only, for the reason `CopilotSessionLog.activity` is: the transcript lives on
  /// whichever machine ran the agent, and carrying beats back through a remote shell is a
  /// larger change than this one. Remote loops keep the card line they already had.
  public static func summary(of node: LoopNode, projectPath: String? = nil) async
    -> SummaryReading?
  {
    if let projectPath, RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      return nil
    }
    guard let sessionID = SessionIDStore.load(forNodeID: node.id),
      let transcript = transcript(forSessionID: sessionID),
      await TranscriptFreshness.shared.hasChanged(transcript, forNode: node.id)
    else { return nil }
    let reading = reading(inTranscriptAt: transcript, metricSamples: node.metricHistory)
    return reading.isEmpty ? nil : reading
  }
}

/// How the one number the rail carries is written.
///
/// Which pass a movement belongs to is `LoopSummary.delta`'s answer, and it is matched on
/// *when* the sample was taken. Keying the series by position — sample *n* to pass *n* —
/// was the first version, and it printed a real movement under a pass it did not happen
/// in as soon as a human typed twice in one pass.
///
/// The values themselves come off `metricHistory` unrecomputed: that series is what the
/// sparkline and the plateau rule already use, so a pass line saying `1.4k → 1.3k` and a
/// bar chart disagreeing is impossible by construction.
public enum LoopSummaryDeltas {
  /// Short enough for a 188pt line: `1.4k`, `0.62`, `312`.
  public static func number(_ value: Double) -> String {
    let magnitude = abs(value)
    if magnitude >= 1000 {
      return String(format: "%.1fk", value / 1000)
    }
    if magnitude >= 100 || value == value.rounded() {
      return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
  }
}
