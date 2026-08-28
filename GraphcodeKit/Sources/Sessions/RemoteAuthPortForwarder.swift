import Foundation

/// Carries a remote sign-in's localhost callback home: one `ssh -N -L` per
/// `(host, port)`, started when a link from that host's terminal names the port
/// (`AuthCallbackPorts`) and the Mac's browser is about to be opened on it.
///
/// The `-L` twin of `RemoteSocketForwarder`'s `-R`: a CLI in the remote session
/// (`az login`, `claude`, `codex login`) binds `localhost:<port>` *there* and waits
/// for the OAuth redirect; the browser completing that redirect runs *here*. Without
/// the forward the redirect dies on the Mac's own loopback and the CLI waits forever
/// — the whole sign-in reads as hung.
///
/// No retry loop, unlike the socket forwarder: a sign-in is interactive and brief,
/// and the human's next click on the link re-ensures the forward. `ExitOnForwardFailure`
/// makes a local bind conflict (something already on that port here) exit rather than
/// sit connected and useless. Forwards are kept for the app's lifetime — a handful of
/// idle ssh processes at most, and a second sign-in on the same port reuses the first's.
public actor RemoteAuthPortForwarder {
  public static let shared = RemoteAuthPortForwarder()

  private var forwards: [String: Process] = [:]

  public func ensureForwarding(port: Int, to location: RemoteProjectLocation) {
    let key = "\(location.authority):\(port)"
    if let existing = forwards[key], existing.isRunning { return }
    let invocation = Self.forwardInvocation(port: port, to: location)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation[0])
    process.arguments = Array(invocation.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      forwards[key] = process
    } catch {}
  }

  /// The dial: gh for a codespace (the forward rides past `--` as ssh-flags, no
  /// destination — gh names it), plain ssh otherwise. Same keepalive posture as every
  /// other dial, so a dropped link dies visibly instead of at the TCP timeout.
  public static func forwardInvocation(
    port: Int, to location: RemoteProjectLocation
  ) -> [String] {
    let spec = "\(port):localhost:\(port)"
    let options = [
      "-N", "-L", spec,
      "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if location.isCodespace {
      return [GhLocator.executablePath, "codespace", "ssh", "-c", location.host, "--"]
        + options
    }
    var invocation = ["/usr/bin/ssh"] + options
    if let sshPort = location.port { invocation += ["-p", String(sshPort)] }
    invocation.append(location.sshDestination)
    return invocation
  }
}
