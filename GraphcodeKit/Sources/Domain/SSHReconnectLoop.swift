import Foundation

/// A local `/bin/sh` retry loop around two ssh command lines, for the failure it exists
/// to survive: a live surface whose ssh
/// drops (a Codespace idle-stopping, sleep, a network change) died on screen even though
/// the remote zmx session kept the agent running, and recovery meant closing and
/// reopening the loop's terminal by hand.
///
/// `connect` runs once — the create-or-attach dial the surface always made. ssh reserves
/// exit 255 for its own connection errors, so 255 retries `reconnect` (attach-only; see
/// `GhosttyTerminalView.remoteCommand` for why it must never re-run the agent command)
/// with capped exponential backoff, forever — an overnight sleep still resumes. Every
/// other exit passes through, closing the surface exactly like a local shell exit.
///
/// 255 also covers permanent ssh failures (auth, host key, DNS), which therefore retry
/// too; the banner names the exit code and ssh's own error text stays visible above it.
/// Ctrl-C during the wait is the escape hatch — the `trap` makes it deterministic, and
/// while ssh is live the tty is raw so Ctrl-C goes to the remote side instead.
///
/// `retriesExitOne` is the Codespace accommodation: `gh` runs ssh but does not
/// propagate its exit code — every nonzero exit (ssh's 255 *and* the remote scripts'
/// deliberate `exit 255`s) surfaces as gh's own 1, with only 0 preserved. A gh dial
/// therefore retries on 1 as well. That also redials a session that genuinely ended
/// nonzero, which converges: the redial reattaches a live session, and a gone one
/// takes the reconnect script's session-ended branch to a clean exit 0.
public enum SSHReconnectLoop {
  public static let maxDelaySeconds = 15

  public static func script(
    connect: String, reconnect: String, retriesExitOne: Bool = false
  ) -> String {
    let passExit =
      retriesExitOne
      ? "; gc_rc=$?; { [ \"$gc_rc\" -ne 255 ] && [ \"$gc_rc\" -ne 1 ]; } && exit \"$gc_rc\""
      : "; gc_rc=$?; [ \"$gc_rc\" -ne 255 ] && exit \"$gc_rc\""
    return "trap 'exit 130' INT; "
      + connect + passExit + "; "
      + "gc_delay=1; while :; do "
      + #"printf '\033[1;33m── Connection failed (exit %s). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$gc_rc" "$gc_delay"; "#
      + "sleep \"$gc_delay\"; gc_delay=$((gc_delay * 2)); "
      + "[ \"$gc_delay\" -gt \(maxDelaySeconds) ] && gc_delay=\(maxDelaySeconds); "
      + reconnect + passExit + "; done"
  }
}
