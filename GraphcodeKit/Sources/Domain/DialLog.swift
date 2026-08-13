import Foundation

/// One line per launch decision, written on the machine that made it — the record that
/// turns "my loop restarted from scratch" into a diagnosis instead of a forensic
/// reconstruction from transcript birth times.
///
/// Every dial that can create, resume, or refuse to touch a session appends
/// `<utc-time> <session> <dial> <branch>` to `~/.graphcode/dials.log` on the host the
/// session lives on: a remote loop's pane scripts and the daemon's remote ensure log on
/// the remote host, right beside the banked session IDs they consume; the daemon's
/// local launches and the local pane log here. The pane banners announce the same
/// decisions, but they die with the scrollback.
///
/// Bounded before every append: past `maxBytes` the file is trimmed to its last
/// `keptLines` lines (~5000 lines is roughly 400 KB of these), so a reconnect loop
/// that waits all night cannot eat a disk.
public enum DialLog {
  public static let maxBytes = 1_048_576
  public static let keptLines = 5000
  static let logExpression = "\"$HOME/.graphcode/dials.log\""

  /// The append as a shell fragment, safe anywhere in an `&&` chain: braced, silenced,
  /// and `|| true`d — a full disk or a read-only home must never break the dial it
  /// rides on. `session`, `dial`, and `event` are interpolated into the `printf`
  /// format, which is fine for the values this codebase passes (session names are
  /// `graphcode-<uuid>`, the rest are literals here) and would not be for user text.
  public static func fragment(session: String, dial: String, event: String) -> String {
    let log = logExpression
    return "{ mkdir -p \"$HOME/.graphcode\"; "
      + "gc_dl=$(wc -c < \(log) 2>/dev/null || echo 0); "
      + "[ \"${gc_dl:-0}\" -gt \(maxBytes) ] "
      + "&& { tail -n \(keptLines) \(log) > \(log).tmp && mv \(log).tmp \(log); }; "
      + "printf '%s \(session) \(dial) \(event)\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
      + ">> \(log); } 2>/dev/null || true"
  }

  /// The same line from Swift, for the launches the daemon decides locally rather than
  /// in a remote shell. Best-effort by the same rule: failure to log must never fail a
  /// launch.
  public static func record(
    session: String, dial: String, event: String,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    let fileManager = FileManager.default
    let directory = home.appendingPathComponent(".graphcode", isDirectory: true)
    let log = directory.appendingPathComponent("dials.log")
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(session) \(dial) \(event)\n"
    let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? Int ?? 0
    if size > maxBytes, let contents = try? String(contentsOf: log, encoding: .utf8) {
      let kept = contents.split(separator: "\n").suffix(keptLines).joined(separator: "\n")
      try? (kept + "\n" + line).write(to: log, atomically: true, encoding: .utf8)
      return
    }
    if let handle = try? FileHandle(forWritingTo: log) {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
      try? handle.close()
    } else {
      try? line.write(to: log, atomically: true, encoding: .utf8)
    }
  }
}
