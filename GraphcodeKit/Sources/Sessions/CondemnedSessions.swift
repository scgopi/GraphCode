import Foundation

/// The sessions graphcode has decided must die, recorded durably *before* the first
/// kill is attempted (#196).
///
/// A detached `zmx` session outlives everything except an explicit `zmx kill` or a
/// reboot, and deleting a loop destroys the graph node — the only other handle on it.
/// The old shape fired one unawaited kill and dropped the node: a kill that missed (a
/// transient `zmx` error, the daemon booted out mid-update with the detached task in
/// flight) leaked the session's PTY until reboot, and enough of them exhausts the
/// machine's `kern.tty.ptmx_max`. Writing the name here first turns the delete into a
/// two-phase affair: the intent survives the daemon, and `reap` retries at the next
/// startup and on a timer until the session is confirmed gone.
///
/// Deliberately *not* a "kill any session without a node" sweep: the zmx namespace is
/// shared across workspaces, and each workspace's daemon knows only its own nodes — a
/// blanket sweep from one would shoot another's live loops. Each daemon reaps only what
/// it condemned, under its own support directory.
public actor CondemnedSessions {
  public static let shared = CondemnedSessions()

  private let fileURL: URL

  public init(directory: URL = SupportDirectory.url) {
    fileURL = directory.appendingPathComponent("condemned-sessions.txt")
  }

  /// Records that `name` must be killed. Idempotent, and written before returning so a
  /// daemon that dies in the next instant still leaves the intent on disk.
  public func condemn(_ name: String) {
    var names = load()
    guard !names.contains(name) else { return }
    names.append(name)
    save(names)
  }

  /// Clears `name` after its death has been *confirmed* — never merely attempted.
  public func absolve(_ name: String) {
    let names = load().filter { $0 != name }
    save(names)
  }

  public func names() -> [String] {
    load()
  }

  private func load() -> [String] {
    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  private func save(_ names: [String]) {
    let content = names.joined(separator: "\n")
    if names.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
    } else {
      try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }
}
