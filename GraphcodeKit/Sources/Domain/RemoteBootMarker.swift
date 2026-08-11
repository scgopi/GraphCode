import Foundation

/// Tells apart the reconnect dial's one ambiguous observation: `zmx get` reporting "no
/// such session" means either the loop finished while disconnected *or* the host
/// rebooted and took every session with it. The two demand opposite reactions — closing
/// the pane versus restoring the session — and nothing in the exit code distinguishes
/// them.
///
/// The marker is the boot the pane last attached under, kept with the other per-session
/// state under `~/.graphcode`. A reconnect that finds the session gone compares the
/// current boot against it: same boot → the session ended on its own, close as before;
/// different boot → the session died with the machine, which is
/// `GhosttyTerminalView.remoteCommand`'s cue to restore it instead — see the restore
/// branch there.
///
/// The probe reads Linux's per-boot UUID and falls back to macOS's
/// `kern.bootsessionuuid` — a UUID minted per boot, not `kern.boottime`, which is
/// derived from the clock and shifts when NTP steps it after a wake, faking a reboot
/// that never happened. A host offering neither captures empty, which the reconnect
/// treats as "unknown" and keeps the pre-marker behaviour; so does a session attached
/// before the marker existed, whose file is simply absent until the next attach writes
/// one.
public enum RemoteBootMarker {
  /// Assigns the current boot's identity to `gc_boot`, or empty when unknowable.
  public static let captureFragment =
    "gc_boot=$({ cat /proc/sys/kernel/random/boot_id || sysctl -n kern.bootsessionuuid; } 2>/dev/null)"

  /// Where one session's marker lives, as `$HOME` shell text — the file is on the
  /// session's host, and only a shell there knows that home directory (the
  /// `PresenceHooks.remoteSessionsExpression` arrangement).
  public static func markerExpression(forSessionName name: String) -> String {
    "\"$HOME/.graphcode/boots/\(name)\""
  }

  /// Captures and records the current boot for `name`. Never fails, so it can sit in an
  /// `&&` chain without a marker problem aborting the attach it precedes.
  public static func writeFragment(forSessionName name: String) -> String {
    "{ \(captureFragment); mkdir -p \"$HOME/.graphcode/boots\" && "
      + "printf '%s' \"$gc_boot\" >\(markerExpression(forSessionName: name)); } 2>/dev/null || true"
  }
}
