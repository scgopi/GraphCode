import Foundation

/// When a codespace that stopped answering may be dialed again (issue #480).
///
/// Every Codespace dial is `gh codespace ssh`, and every gh run costs calls against the
/// human's per-user Codespaces rate limit — around a hundred while a codespace is
/// starting. Retrying on each reader's own clock spent that limit during every outage,
/// so all dialers share this one schedule, counted from the first failure: retry freely
/// for a minute, hold until the third, retry again until the fourth, then pause: one dial
/// every `slowRetryInterval` until the codespace answers, or at once when a human asks to
/// reconnect. The pause never ends in silence, because a codespace restarted from
/// outside graphcode can take longer than four minutes to come back, and its loops
/// should recover without a human finding them dead.
///
/// The daemon applies it in `CodespaceDialBreaker`; a terminal pane applies the same
/// numbers inside its shell loop (`SSHReconnectLoop`), which runs in another process.
public struct CodespaceDialSchedule: Equatable, Sendable {
  public var freeRetryWindow: Int
  public var holdUntil: Int
  public var pauseAfter: Int
  public var slowRetryInterval: Int

  public init(
    freeRetryWindow: Int = 60, holdUntil: Int = 180, pauseAfter: Int = 240,
    slowRetryInterval: Int = 300
  ) {
    self.freeRetryWindow = freeRetryWindow
    self.holdUntil = holdUntil
    self.pauseAfter = pauseAfter
    self.slowRetryInterval = slowRetryInterval
  }

  public static let standard = CodespaceDialSchedule()

  public enum Verdict: Equatable, Sendable {
    case dial
    case hold
    case paused
  }

  /// `secondsDown` is how long the codespace has been failing; `nil` means it is not.
  public func verdict(secondsDown: TimeInterval?) -> Verdict {
    guard let secondsDown else { return .dial }
    if secondsDown >= TimeInterval(pauseAfter) { return .paused }
    if secondsDown >= TimeInterval(freeRetryWindow), secondsDown < TimeInterval(holdUntil) {
      return .hold
    }
    return .dial
  }
}
