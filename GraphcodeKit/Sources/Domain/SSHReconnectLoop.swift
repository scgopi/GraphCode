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
/// A Codespace surface uses `codespaceScript` instead, which retries on a schedule rather
/// than forever.
public enum SSHReconnectLoop {
  public static let maxDelaySeconds = 15

  /// `redialStamp` is touched before every redial: it is how `graphcoded` learns, for
  /// free, that a host may have rebooted under a loop it restores
  /// (`ZmxSessionLauncher.restoreRebootedRemote`).
  public static func script(
    connect: String, reconnect: String, redialStamp: String? = nil
  ) -> String {
    let passExit = "; gc_rc=$?; [ \"$gc_rc\" -ne 255 ] && exit \"$gc_rc\""
    return "trap 'exit 130' INT; "
      + connect + passExit + "; "
      + "gc_delay=1; while :; do "
      + #"printf '\033[1;33m── Connection failed (exit %s). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$gc_rc" "$gc_delay"; "#
      + "sleep \"$gc_delay\"; gc_delay=$((gc_delay * 2)); "
      + "[ \"$gc_delay\" -gt \(maxDelaySeconds) ] && gc_delay=\(maxDelaySeconds); "
      + touching(redialStamp) + reconnect + passExit + "; done"
  }

  /// A Codespace surface's loop: the same dials and exit handling, retried on
  /// `CodespaceDialSchedule` instead of forever, because every gh run spends the human's
  /// Codespaces rate limit (issue #480). Past `schedule.pauseAfter` it redials once per
  /// `schedule.slowRetryInterval`, or at once on Enter, which also touches `pauseMarker`
  /// so `graphcoded`'s `CodespaceDialBreaker` resumes the codespace's reads and ensures
  /// with it. The app touches the same marker when a loop of this codespace is selected,
  /// which restarts the schedule and redials from any wait — held or paused — within a
  /// second.
  ///
  /// The outage clock restarts only after a dial that lasted `upAfter`, longer than the
  /// five minutes gh can spend waiting for a codespace to start before failing — a
  /// shorter dial may never have reached the codespace at all.
  ///
  /// Exit 1 retries as well as 255: `gh` runs ssh but does not propagate its exit code —
  /// every nonzero exit (ssh's 255 *and* the remote scripts' deliberate `exit 255`s)
  /// surfaces as gh's own 1, with only 0 preserved. That also redials a session that
  /// genuinely ended nonzero, which converges: the redial reattaches a live session, and
  /// a gone one takes the reconnect script's session-ended branch to a clean exit 0.
  public static func codespaceScript(
    connect: String, reconnect: String, pauseMarker: String, redialStamp: String? = nil,
    schedule: CodespaceDialSchedule = .standard, upAfter: Int = 330
  ) -> String {
    let marker = quoted(pauseMarker)
    let directory = quoted(URL(fileURLWithPath: pauseMarker).deletingLastPathComponent().path)
    let passExit =
      "; gc_rc=$?; { [ \"$gc_rc\" -ne 255 ] && [ \"$gc_rc\" -ne 1 ]; } && exit \"$gc_rc\""
    // `touch`, not `: >`: a failed redirection on the special builtin `:` exits a POSIX
    // shell, which would close the pane over an unwritable temp directory.
    let restart = "gc_down=$(date +%s); gc_delay=1; touch \"$gc_stamp\" 2>/dev/null"
    let clock =
      "; { [ -z \"$gc_down\" ] || [ $(($(date +%s) - gc_t)) -ge \(upAfter) ]; } && { \(restart); }"
    // A marker newer than the stamp is a human asking to reconnect now; the stamp is
    // re-touched whenever the outage clock starts, so the click that opened the pane
    // does not count.
    let asked = "{ [ -e \"$gc_stamp\" ] && [ \(marker) -nt \"$gc_stamp\" ]; }"
    let enter = "mkdir -p \(directory) 2>/dev/null; touch \(marker) 2>/dev/null"
    // On a tty the pause polls, so a selection can end it too, and runs out after the slow
    // retry interval to redial on the same outage clock. Off one, `read` blocks as it
    // always did: bash 3.2's `read -t` answers 1 for a timeout and for end of input alike,
    // and a closed stdin would spin. A pane always has a tty.
    let pause =
      "gc_ask=; if [ -t 0 ]; then gc_left=\(schedule.slowRetryInterval); "
      + "while [ \"$gc_left\" -gt 0 ]; do \(asked) && { gc_ask=1; break; }; "
      + "read -t 1 gc_line && { \(enter); gc_ask=1; break; }; gc_left=$((gc_left - 1)); done; "
      + "else read gc_line || exit 0; \(enter); gc_ask=1; fi; "
    let waitOrAsk =
      "gc_wait_or_ask() { gc_left=$1; while [ \"$gc_left\" -gt 0 ]; do "
      + "\(asked) && return 0; sleep 1; gc_left=$((gc_left - 1)); done; return 1; }; "
    return "trap 'exit 130' INT; trap 'rm -f \"$gc_stamp\"' EXIT; "
      + "gc_stamp=$(mktemp -t graphcode-dial 2>/dev/null) "
      + "|| gc_stamp=\"${TMPDIR:-/tmp}/graphcode-dial.$$\"; touch \"$gc_stamp\" 2>/dev/null; "
      + "gc_down=; gc_delay=1; gc_t=$(date +%s); "
      + waitOrAsk
      + connect + passExit + clock + "; "
      + "while :; do gc_out=$(($(date +%s) - gc_down)); "
      + "if [ \"$gc_out\" -ge \(schedule.pauseAfter) ]; then "
      + #"printf '\033[1;33m── Codespace still unreachable (exit %s). Paused to save your "#
      + #"Codespaces API quota; retrying every %ss. Press Enter or select the loop to "#
      + #"reconnect now, Ctrl-C to close. ──\033[0m\r\n' "$gc_rc" "#
      + "\(schedule.slowRetryInterval); "
      + pause + "[ -n \"$gc_ask\" ] && { \(restart); }; "
      + "else "
      + "if [ \"$gc_out\" -ge \(schedule.freeRetryWindow) ] "
      + "&& [ \"$gc_out\" -lt \(schedule.holdUntil) ]; then "
      + "gc_wait=$((\(schedule.holdUntil) - gc_out)); else gc_wait=$gc_delay; "
      + "gc_delay=$((gc_delay * 2)); "
      + "[ \"$gc_delay\" -gt \(maxDelaySeconds) ] && gc_delay=\(maxDelaySeconds); fi; "
      + #"printf '\033[1;33m── Connection failed (exit %s). Retrying in %ss. "#
      + #"Press Ctrl-C to stop. ──\033[0m\r\n' "$gc_rc" "$gc_wait"; "#
      + "gc_wait_or_ask \"$gc_wait\" && { \(restart); }; fi; "
      + "gc_t=$(date +%s); " + touching(redialStamp) + reconnect + passExit + clock + "; done"
  }

  private static func touching(_ stamp: String?) -> String {
    stamp.map { "touch \(quoted($0)) 2>/dev/null; " } ?? ""
  }

  /// `RemoteProjectLocation.shellQuoted`, repeated because this file also builds in the
  /// portable package, which leaves that type out.
  private static func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
