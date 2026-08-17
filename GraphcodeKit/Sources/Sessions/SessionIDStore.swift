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

  static func file(forNodeID nodeID: UUID) -> URL {
    directory.appendingPathComponent("\(nodeID.uuidString).id")
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
