import Foundation

/// Which process, if any, currently has a workspace open.
///
/// Two app instances over one support directory is the failure `SupportDirectory`'s own
/// documentation warns about — the same graphs, the same terminal layouts, and therefore
/// the same `zmx` session names, with both apps attaching to one session and taking it
/// down under each other. Opening workspaces from a menu makes that a thing a human can
/// now do by accident, so each instance records itself and the launcher raises the window
/// that already exists instead of starting a second one.
///
/// A pid file rather than a lock: the answer this needs is "who", not "may I" — the
/// launcher wants a process to activate. Staleness is decided by asking the kernel about
/// the pid rather than by trusting the file, because a crashed app never gets to clean up.
public enum WorkspaceLock {
  public static func url(for workspace: Workspace) -> URL {
    workspace.url.appendingPathComponent("app.pid")
  }

  /// Records this process as the workspace's, unless a live process already holds it —
  /// in which case that one is still the owner and this is the interloper.
  ///
  /// Claiming unconditionally looked simpler and was wrong: any second process that
  /// touches a workspace (the test host launching the app, an instance started around the
  /// guard) would overwrite the running app's claim with its own, and once *it* exited the
  /// workspace would read as free while a real window was still using it.
  ///
  /// Returns whether the claim is now this process's.
  @discardableResult
  public static func claim(
    _ workspace: Workspace = .current, pid: Int32 = ProcessInfo.processInfo.processIdentifier
  ) -> Bool {
    if let holder = holder(of: workspace), holder != pid { return false }
    try? Data("\(pid)\n".utf8).write(to: url(for: workspace), options: .atomic)
    return true
  }

  /// Drops the claim, when the file still names this process. The guard matters on the
  /// path where an instance quits *after* another has taken the workspace over — a
  /// relaunch, say — where deleting unconditionally would erase the live claim.
  public static func release(
    _ workspace: Workspace = .current, pid: Int32 = ProcessInfo.processInfo.processIdentifier
  ) {
    guard recordedPID(for: workspace) == pid else { return }
    try? FileManager.default.removeItem(at: url(for: workspace))
  }

  /// The live process holding this workspace, or `nil` — no file, unreadable, or a pid
  /// nothing is running under any more.
  ///
  /// A pid that is alive is not proof it is *graphcode* — pids are reused. Callers that
  /// can check (the app, which has `NSRunningApplication`) should; the worst a caller
  /// that can't does is decline to open a workspace it could have opened.
  public static func holder(of workspace: Workspace) -> Int32? {
    guard let pid = recordedPID(for: workspace), isRunning(pid) else { return nil }
    return pid
  }

  static func recordedPID(for workspace: Workspace) -> Int32? {
    guard let text = try? String(contentsOf: url(for: workspace), encoding: .utf8) else {
      return nil
    }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// `kill(pid, 0)` sends nothing; it just asks. `EPERM` means the process exists and
  /// belongs to someone else, which for this question is still "alive".
  static func isRunning(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
  }
}
