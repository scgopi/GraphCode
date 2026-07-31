import Foundation

/// A project whose working tree lives on another machine, reached over SSH — the
/// docs/09-remote-repositories.md Phase B model, drawn on supacode's remote connections
/// (shape, not code).
///
/// **The project path *is* the identity.** A remote project's path is the URI
/// `ssh://user@host[:port]/absolute/path`, following the precedent the global graph set
/// (`graphcode://global`): the daemon keys graphs by path string, the app keys sidebar
/// rows by it, and a URI that embeds the host can never collide with a local folder or
/// with the same folder on a different machine. Everything that treats a project path as
/// a *directory* branches on `parse` returning non-nil.
///
/// **The daemon stays local.** Every remote effect is "run a command over ssh": the
/// session is a `zmx` session on the remote host, started and attached through
/// `sshInvocation`. What that buys — and what it costs (no edge firing while the Mac
/// sleeps) — is docs/09's trade, made deliberately.
public struct RemoteProjectLocation: Equatable, Sendable {
  public var user: String?
  public var host: String
  public var port: Int?
  /// Absolute path of the repository on the remote machine.
  public var remotePath: String

  public init(user: String? = nil, host: String, port: Int? = nil, remotePath: String) {
    self.user = user
    self.host = host
    self.port = port
    self.remotePath = remotePath
  }

  /// The reserved scheme. A path with this prefix is a remote project everywhere a
  /// project path travels.
  public static let scheme = "ssh"

  /// Parses a project path, returning `nil` for anything that isn't a remote one —
  /// which is the branch every existing call site takes for ordinary folders.
  public static func parse(projectPath: String) -> RemoteProjectLocation? {
    guard projectPath.hasPrefix("\(scheme)://"),
      let components = URLComponents(string: projectPath),
      components.scheme == scheme,
      let host = components.host, !host.isEmpty,
      !components.path.isEmpty, components.path.hasPrefix("/")
    else { return nil }
    return RemoteProjectLocation(
      user: components.user, host: host, port: components.port, remotePath: components.path)
  }

  /// The path string this location travels as — `parse`'s inverse.
  public var projectPath: String {
    "\(Self.scheme)://\(authority)\(remotePath)"
  }

  /// `user@host` / `user@host:port` — what `ssh` is pointed at (port rides separately
  /// as `-p`, but the authority string carries it for identity and display).
  public var authority: String {
    let userPart = user.map { "\($0)@" } ?? ""
    let portPart = port.map { ":\($0)" } ?? ""
    return "\(userPart)\(host)\(portPart)"
  }

  /// What ssh itself is told to connect to — the authority without the port.
  public var sshDestination: String {
    let userPart = user.map { "\($0)@" } ?? ""
    return "\(userPart)\(host)"
  }

  /// The sidebar title: the repository folder's name, with the host to tell it apart
  /// from a local checkout of the same project.
  public var displayName: String {
    let leaf = remotePath.split(separator: "/").last.map(String.init) ?? remotePath
    return "\(leaf) @ \(host)"
  }

  /// POSIX single-quote escaping — the one quoting rule that survives every layer here.
  /// ssh joins its command arguments with spaces and hands the result to the remote
  /// login shell, so every remote command is built as one string with each embedded
  /// value quoted by this; nesting works because a quoted string is itself safe to
  /// quote again.
  public static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// The local argv that runs `remoteCommand` on this host.
  ///
  /// `BatchMode=yes` because nothing launched by the app or daemon has a tty to answer
  /// a password prompt — key auth or fail fast, the same rule the clone form applies.
  /// `interactive` adds `-t`: a terminal surface needs the remote side to have a tty
  /// (zmx attaches a full-screen session), where a launch/query must *not* take one.
  ///
  /// `ServerAlive*` on every connection: without keepalives a dead link (a Codespace
  /// idle-stopping, a network change) is only discovered at the OS TCP timeout, which
  /// reads as a frozen terminal. 5s × 3 bounds detection at ~15s, and an interactive
  /// surface's exit-255 is what the reconnect loop (`SSHReconnectLoop`) retries on.
  public func sshInvocation(remoteCommand: String, interactive: Bool = false) -> [String] {
    var invocation = ["/usr/bin/ssh"]
    if interactive { invocation.append("-t") }
    invocation += [
      "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if let port { invocation += ["-p", String(port)] }
    invocation += [sshDestination, "--", remoteCommand]
    return invocation
  }

  /// The `sshInvocation` argv as one `/bin/sh`-safe string — every token single-quoted —
  /// for the one caller that embeds an ssh dial *inside* a local shell script rather
  /// than exec'ing it directly: the surface reconnect loop, which needs the dial as a
  /// line it can re-run.
  public func sshCommandLine(remoteCommand: String, interactive: Bool = false) -> String {
    sshInvocation(remoteCommand: remoteCommand, interactive: interactive)
      .map(Self.shellQuoted).joined(separator: " ")
  }

  /// Wraps a remote command so it resolves `PATH` the way a human's terminal would —
  /// the remote twin of `ZmxSessionLauncher.loginShellInvocation`, and `-i` is
  /// load-bearing for the same reason: the remote `~/.zshrc` is what knows where `zmx`
  /// and the agent live, and zsh reads it only when interactive.
  public func remoteLoginShellCommand(_ script: String) -> String {
    "exec zsh -l -i -c \(Self.shellQuoted(script))"
  }
}
