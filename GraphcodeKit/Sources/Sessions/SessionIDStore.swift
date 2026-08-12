import Foundation

/// Persists each node's backend session ID so a loop can resume after a reboot
/// instead of starting a duplicate session from scratch.
///
/// The zmx session holds the PTY and survives app quits, but not a reboot — its
/// server process dies with the machine. Without this store, `ensureUnattendedSessions`
/// relaunches every loop with its opening prompt, doing the same job twice. With it,
/// the launcher can pass `--resume <id>` instead, picking up where the last session
/// left off.
///
/// Files live at `~/.graphcode/sessions/<node-uuid>.id`, one line per file. Written
/// by a `SessionStart` hook inside the backend (see `PresenceHooks`), read by
/// `ZmxSessionLauncher` before it decides whether to start fresh or resume.
public enum SessionIDStore {
  static var directory: URL {
    SupportDirectory.url.appendingPathComponent("sessions", isDirectory: true)
  }

  /// Public because the app's own launch path reads this file too — see
  /// `GhosttyTerminalView.localResumeOrFreshCommand`, which resumes rather than
  /// re-prompting when a loop is opened with its session gone.
  public static func file(forNodeID nodeID: UUID) -> URL {
    directory.appendingPathComponent("\(nodeID.uuidString).id")
  }

  /// Every ID this node has ever banked, appended one line per session start as
  /// `<epoch> <session-id> <cwd>`.
  ///
  /// The pointer is last-writer-wins by design — a new session for a node *is* the
  /// node's session now. What that cannot survive is a session started against a
  /// conversation the node had already moved on from: the pointer swings to a transcript
  /// with nothing in it, and the one that holds the work is unreachable, with nothing on
  /// disk recording that it ever existed. Recovering a real case of this (2026-08-11)
  /// meant reading transcript sizes and birth times out of `~/.claude/projects` and
  /// guessing — forensics, not a supported operation.
  ///
  /// Append-only and never read by the launcher: this exists so a human (or a repair
  /// command) can see what the pointer used to be. Truncation is deliberately absent —
  /// a line per session start is a handful of bytes a week.
  public static func historyFile(forNodeID nodeID: UUID) -> URL {
    directory.appendingPathComponent("\(nodeID.uuidString).history")
  }

  /// The IDs banked for this node, newest last, as `(sessionID, cwd)`. Empty when the
  /// node predates the history or nothing was ever recorded.
  public static func history(forNodeID nodeID: UUID) -> [(
    sessionID: String, workingDirectory: String
  )] {
    guard let text = try? String(contentsOf: historyFile(forNodeID: nodeID), encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
      let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count >= 2 else { return nil }
      return (String(fields[1]), fields.count > 2 ? String(fields[2]) : "")
    }
  }

  public static func save(_ sessionID: String, forNodeID nodeID: UUID) {
    let url = file(forNodeID: nodeID)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try sessionID.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      return
    }
  }

  public static func load(forNodeID nodeID: UUID) -> String? {
    let url = file(forNodeID: nodeID)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public static func remove(forNodeID nodeID: UUID) {
    try? FileManager.default.removeItem(at: file(forNodeID: nodeID))
  }
}
