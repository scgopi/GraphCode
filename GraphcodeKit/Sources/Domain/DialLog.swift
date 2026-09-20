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
/// `keptLines` lines, so a reconnect loop that waits all night cannot eat a disk.
///
/// That bound is a *line-count* trim standing in for a byte budget, which only holds
/// while a line stays under `maxBytes / keptLines` — 209 bytes. A longer one breaks it
/// permanently: the trim keeps 5000 lines, 5000 long lines are still over `maxBytes`,
/// so every later append by every loop on the host re-reads and rewrites the whole file
/// and never gets under. Anything writing a variable-length field here must size it
/// against that budget rather than pick a number.
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
    "{ mkdir -p \"$HOME/.graphcode\"; " + trimFragment
      + "printf '%s \(session) \(dial) \(event)\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
      + ">> \(logExpression); } 2>/dev/null || true"
  }

  /// The bound, as both fragments run it: trim to the last `keptLines` when the file has
  /// grown past `maxBytes`.
  ///
  /// The scratch file is per-process (`$$`). It used to be a fixed `dials.log.tmp`, which
  /// is a race every loop on a host shares: two dials trimming at once both redirect into
  /// the same name and both `mv` it, and the second `mv` publishes a file the first was
  /// still writing — measured at 40 concurrent fragments, a 5000-line log came out with
  /// 34 lines, which is the launch history gone. It was survivable only because trimming
  /// was rare; a per-process name makes each writer's file its own and the `mv` that
  /// publishes it atomic.
  private static var trimFragment: String {
    let log = logExpression
    return "gc_dl=$(wc -c < \(log) 2>/dev/null || echo 0); "
      + "[ \"${gc_dl:-0}\" -gt \(maxBytes) ] "
      + "&& { tail -n \(keptLines) \(log) > \(log).$$.tmp "
      + "&& mv \(log).$$.tmp \(log); }; "
  }

  /// `fragment`, with the contents of a shell variable appended as a trailing detail —
  /// for the one caller that has something to say beyond which branch it took: a failed
  /// delivery, whose whole problem was leaving no trace of *why*.
  ///
  /// The value rides as a `printf` **argument** rather than inside the format, unlike
  /// `session`, `dial` and `event`. Those are literals this codebase controls; this one
  /// is an error message from a remote python, and a `%s` or a stray backslash in it
  /// would otherwise reformat the line it is being written to. Callers are responsible
  /// for flattening newlines out of the variable first — the log is one line per entry,
  /// and every reader of it splits on them.
  /// Callers are also responsible for keeping the value inside the per-line budget the
  /// trim depends on — see `RemoteGraphAccess.errorDetailBytes`, which derives its size
  /// from `maxBytes / keptLines` for exactly that reason.
  public static func fragment(
    session: String, dial: String, event: String, detailVariable: String
  ) -> String {
    "{ mkdir -p \"$HOME/.graphcode\"; " + trimFragment
      + "printf '%s \(session) \(dial) \(event) %s\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" "
      + "\"$\(detailVariable)\" >> \(logExpression); } 2>/dev/null || true"
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
