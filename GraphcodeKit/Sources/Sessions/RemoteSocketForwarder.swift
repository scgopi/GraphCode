import Foundation

/// Keeps one `ssh -N -R` alive per remote host, putting the local daemon's socket at
/// the *canonical* path on that host — `~/.graphcode/graphcoded.sock` — so the
/// delivered `graphcode` shim needs no configuration to find it: the same default dial
/// as a local CLI, just answered from across the wire.
///
/// A dedicated persistent connection rather than `-R` on the launch dial, because the
/// dial exits the moment `zmx run` returns and a remote forward lives exactly as long
/// as the connection carrying it. The loop's session outlives every ssh graphcode
/// makes; only a process whose whole job is to stay connected can keep the socket
/// there while the loop works.
///
/// The wrapping shell loop handles the two ways this dies in practice: a dropped
/// connection (retry after a beat, same posture as `SSHReconnectLoop`) and a stale
/// socket left by a crash — sshd refuses to bind over one and, unlike the client-side
/// `StreamLocalBindUnlink`, offers no client-controllable unlink, so each attempt
/// removes the old socket in a short pre-dial and fails fast (`ExitOnForwardFailure`)
/// rather than connecting uselessly. That pre-dial also answers where the socket may
/// bind: `-R` needs an absolute path and nothing local knows the remote home, so the
/// same round-trip prints `$HOME`. The `kill -0 $PPID` guard stops the loop from
/// outliving the daemon that spawned it — a forwarder orphaned by a daemon restart
/// would otherwise fight the replacement's for the bind forever.
public actor RemoteSocketForwarder {
  public static let shared = RemoteSocketForwarder()

  private var forwarders: [String: Process] = [:]

  /// Starts the forwarder for this host unless one is already running. Failures are
  /// quiet on purpose: with no forward, the remote shim's own error says the daemon
  /// is unreachable and why, which is more diagnosable than anything a launcher with
  /// no UI could do from here.
  public func ensureForwarding(to location: RemoteProjectLocation) {
    let key = location.authority
    if let existing = forwarders[key], existing.isRunning { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c", Self.forwardScript(for: location, localSocketPath: DaemonSocketPath.url.path),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      forwarders[key] = process
    } catch {}
  }

  static func forwardScript(for location: RemoteProjectLocation, localSocketPath: String)
    -> String
  {
    let prepare = location.sshCommandLine(
      remoteCommand: "mkdir -p \"$HOME/.graphcode\" && rm -f \"$HOME/.graphcode/graphcoded.sock\""
        + " && printf %s \"$HOME\"")
    let forward = forwardCommandLine(for: location, localSocketPath: localSocketPath)
    return """
      while kill -0 $PPID 2>/dev/null; do \
      H=$(\(prepare)) || { sleep 5; continue; }; \
      \(forward); \
      sleep 5; \
      done
      """
  }

  /// The `ssh -N -R` line itself, with the remote socket path assembled around the
  /// `$H` the pre-dial captured — which is why this is a shell line and not an argv.
  static func forwardCommandLine(for location: RemoteProjectLocation, localSocketPath: String)
    -> String
  {
    var argv = [
      "/usr/bin/ssh", "-N",
      "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if let port = location.port { argv += ["-p", String(port)] }
    let quoted = argv.map(RemoteProjectLocation.shellQuoted) + [
      "-R",
      "\"$H\"" + RemoteProjectLocation.shellQuoted("/.graphcode/graphcoded.sock:" + localSocketPath),
      RemoteProjectLocation.shellQuoted(location.sshDestination),
    ]
    return quoted.joined(separator: " ")
  }
}
