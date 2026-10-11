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
/// claims the path in a short pre-dial and fails fast (`ExitOnForwardFailure`) rather
/// than connecting uselessly. That pre-dial also answers where the socket may bind:
/// `-R` needs an absolute path and nothing local knows the remote home, so the same
/// round-trip prints `$HOME`.
///
/// **The remote socket is the lock.** The app and the daemon each run one of these per
/// host, and the actor below is per process, so neither knows about the other. The
/// pre-dial used to `rm -f` the socket unconditionally, which let a terminal opening in
/// the app delete the daemon's working endpoint and leave every remote CLI call failing
/// while both forwarders still looked alive. Now it removes the path only when a real
/// daemon request through it is refused (`claimCommand`); an answer, or a daemon too busy
/// to answer in time, makes this loop a standby that re-claims on `recheck` and takes
/// over when the other owner's endpoint dies.
///
/// A serving forward never probes or removes anything: it re-checks on the same cadence
/// that the socket it bound is still the one at the path (`checkCommand`, by inode), and
/// steps aside when it is gone or another owner's has replaced it. A stalled connection
/// is ssh's to notice (`ServerAliveInterval`), not this loop's.
///
/// Every dial runs in the background under a one-second `kill -0 $PPID` watch, so a
/// forwarder never outlives the process that spawned it — not even while blocked inside
/// a hung `ssh` or `gh`, which is how forwarders used to end up reparented to launchd,
/// fighting a restarted daemon's for the bind. Each change of state is a `dials.log`
/// line; repeats of the same state are not, since that log is shared with every launch
/// decision on this Mac and a down host would otherwise trim them all away.
public actor RemoteSocketForwarder {
  public static let shared = RemoteSocketForwarder()

  private var forwarders: [String: Process] = [:]

  /// Starts the forwarder for this host unless one is already running — which is now a
  /// sufficient test, since a running one either serves a healthy endpoint or stands by
  /// to take one over. The remote shim's own error still says the daemon is unreachable;
  /// `dials.log` says why.
  public func ensureForwarding(to location: RemoteProjectLocation) {
    #if os(Windows)
      _ = location
      return
    #else
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
      } catch {
        DialLog.record(session: "bridge", dial: Self.owner, event: "spawn-failed")
      }
    #endif
  }

  /// Which process a `dials.log` line came from — the app and the daemon both forward.
  static var owner: String {
    let name = ProcessInfo.processInfo.processName.filter {
      $0.isASCII && ($0.isLetter || $0.isNumber)
    }
    return name.isEmpty ? "unknown" : String(name.prefix(24))
  }

  /// ASCII and bounded in bytes, so a `dials.log` line stays inside the per-line budget
  /// `DialLog`'s trim depends on.
  static func logHost(_ authority: String) -> String {
    String(String.UnicodeScalarView(authority.unicodeScalars.filter(\.isASCII).prefix(64)))
  }

  /// Runs `script` under `/bin/sh` on the remote, whatever the login shell is: sshd hands
  /// the command to the user's shell, and fish or tcsh would reject `if`/`fi` and `2>&1`.
  static func posix(_ script: String) -> String {
    "exec /bin/sh -c " + RemoteProjectLocation.shellQuoted(script)
  }

  /// One framed `listRecentProjects` and the first byte back: an answer proves the whole
  /// path — sshd's listener, the connection carrying it, and the daemon behind it. Exits
  /// 0 when answered, 3 when nothing came back in time, and 1 when the path is refused,
  /// missing, or closed on — only that last is a stale socket. A busy daemon is somebody's
  /// working endpoint, so a timeout must never read as dead.
  static func liveProbe(timeout: Int) -> String {
    "import os,socket,struct,sys;"
      + "sys.excepthook=lambda t,v,b:os._exit(3 if issubclass(t,socket.timeout) else 1);"
      + "s=socket.socket(socket.AF_UNIX);s.settimeout(\(timeout));s.connect(sys.argv[1]);"
      + "m=b'{\"listRecentProjects\":{}}';s.sendall(struct.pack('>I',len(m))+m);"
      + "os._exit(0 if s.recv(1) else 1)"
  }

  /// Prints `live:$HOME` when another forward holds the canonical path, and otherwise
  /// clears it (with the Windows bridge's state, which would shadow it) and prints
  /// `free:$HOME`. Without python3 nothing can be proved either way, so an existing
  /// socket is left alone: the delivered shim needs python3 too, so such a host has no
  /// remote CLI to serve.
  static func claimCommand(probeTimeout: Int = 10) -> String {
    posix(
      "S=\(socketExpression); mkdir -p \"$HOME/.graphcode\" || exit 1;"
        + " if command -v python3 >/dev/null 2>&1; then python3 -c "
        + RemoteProjectLocation.shellQuoted(liveProbe(timeout: probeTimeout))
        + " \"$S\" >/dev/null 2>&1; P=$?; elif [ -S \"$S\" ]; then P=0; else P=1; fi;"
        + " if [ $P -ne 1 ]; then printf 'live:%s' \"$HOME\"; else rm -f \"$S\""
        + " \"$HOME/.graphcode/bridge-state.json\""
        + " \"$HOME/.graphcode/bridge-state-generation\""
        + " \"$HOME/.graphcode/bridge-state.json.lock\""
        + " && printf 'free:%s' \"$HOME\"; fi")
  }

  /// Prints `ino:` and the inode of the socket at the canonical path, or `ino:` alone when
  /// there is none — what a serving forward compares against the one it first saw.
  static var checkCommand: String {
    posix("S=\(socketExpression); [ -S \"$S\" ] && set -- $(ls -di \"$S\"); printf 'ino:%s' \"$1\"")
  }

  static let socketExpression = "\"$HOME/.graphcode/graphcoded.sock\""

  static func forwardScript(for location: RemoteProjectLocation, localSocketPath: String)
    -> String
  {
    let claim = location.sshCommandLine(remoteCommand: claimCommand())
    let check = location.sshCommandLine(remoteCommand: checkCommand)
    let forward = forwardCommandLine(for: location, localSocketPath: localSocketPath)
    let host = logHost(location.authority)
    if location.isCodespace {
      return codespaceForwardScript(claim: claim, check: check, forward: forward, host: host)
    }
    return sshForwardScript(claim: claim, check: check, forward: forward, host: host)
  }

  static func sshForwardScript(
    claim: String, check: String, forward: String, host: String, recheck: Int = 60
  ) -> String {
    supervisor(claim: claim, check: check, forward: forward, host: host, recheck: recheck)
      + """
      while gc_up; do \
      if gc_watch gc_claim; then R=$(cat "$gc_tmp"); \
      case $R in \
      live:*) gc_note standby; gc_nap \(recheck); continue;; \
      free:*) H=${R#free:}; gc_serve;; \
      *) gc_note claim-unreadable;; \
      esac; \
      else gc_note claim-failed; fi; \
      gc_nap 5; \
      done; \
      gc_log parent-gone
      """
  }

  /// A codespace's loop backs off instead of redialing every five seconds, and gives up
  /// once the codespace has been down for `schedule.pauseAfter` — each attempt is two gh
  /// runs against the human's Codespaces rate limit (issue #480). `ensureForwarding`
  /// starts a fresh one on the next ensure, which `CodespaceDialBreaker` lets through only
  /// on its schedule. For the same quota, a standby or a serving forward re-checks the
  /// endpoint every five minutes rather than every one.
  ///
  /// Only a forward that stayed up past `upAfter` proves the codespace was reachable: a
  /// pre-dial can spend up to five minutes inside gh waiting for a codespace to start and
  /// still fail. A `live` answer proves it outright.
  static func codespaceForwardScript(
    claim: String, check: String = "true", forward: String, host: String = "test",
    schedule: CodespaceDialSchedule = .standard, upAfter: Int = 60, maxWait: Int = 60,
    recheck: Int = 300
  ) -> String {
    supervisor(claim: claim, check: check, forward: forward, host: host, recheck: recheck)
      + """
      gc_down=; gc_wait=5; \
      while gc_up; do \
      if gc_watch gc_claim; then R=$(cat "$gc_tmp"); \
      case $R in \
      live:*) gc_note standby; gc_down=; gc_wait=5; gc_nap \(recheck); continue;; \
      free:*) H=${R#free:}; gc_t=$(date +%s); gc_serve; \
      [ $(($(date +%s) - gc_t)) -ge \(upAfter) ] && { gc_down=; gc_wait=5; };; \
      *) gc_note claim-unreadable;; \
      esac; \
      else gc_note claim-failed; fi; \
      gc_now=$(date +%s); gc_down=${gc_down:-$gc_now}; \
      [ $((gc_now - gc_down)) -ge \(schedule.pauseAfter) ] && { gc_log paused; exit 0; }; \
      gc_nap $gc_wait; gc_wait=$((gc_wait * 2)); \
      [ $gc_wait -gt \(maxWait) ] && gc_wait=\(maxWait); \
      done; \
      gc_log parent-gone
      """
  }

  /// The functions both loops share.
  ///
  /// - `gc_watch` runs a dial in the background, into `$gc_tmp` rather than a command
  ///   substitution, and polls: a foreground `ssh` or `gh` that hangs would keep the shell
  ///   from reaching its next `kill -0 $PPID`, and a `$(…)` would hold off the TERM trap
  ///   until it returned.
  /// - `gc_stop` takes the dial's own children with it: a backgrounded function is a
  ///   subshell, and killing only that would orphan the `ssh` it is waiting on.
  /// - `gc_serve` takes the first inode it sees as its own — a bind that failed would have
  ///   ended the forward (`ExitOnForwardFailure`) — and checks every few seconds until it
  ///   has one, since gh can take a while to connect.
  /// - A forward that exits by itself within ten seconds failed to bind; `gc_note` keeps a host that
  ///   refuses every bind to one line.
  static func supervisor(
    claim: String, check: String, forward: String, host: String, recheck: Int
  ) -> String {
    """
    gc_host=\(RemoteProjectLocation.shellQuoted(host)); gc_f=; gc_q=; gc_was=; \
    gc_tmp=$(mktemp "${TMPDIR:-/tmp}/gcbridge.XXXXXX") || exit 1; \
    gc_up() { kill -0 $PPID 2>/dev/null; }; \
    gc_log() { gc_ev="$1 $gc_host ppid=$PPID"; \
    \(DialLog.fragment(session: "bridge", dial: owner, event: "forward", detailVariable: "gc_ev")); }; \
    gc_note() { [ "$1" = "$gc_was" ] || gc_log "$1"; gc_was=$1; }; \
    gc_stop() { [ -n "$1" ] || return 0; pkill -TERM -P $1 2>/dev/null; kill $1 2>/dev/null; }; \
    gc_nap() { gc_i=0; while [ $gc_i -lt $1 ] && gc_up; do sleep 1; gc_i=$((gc_i + 1)); done; }; \
    gc_claim() { \(claim); }; \
    gc_check() { \(check); }; \
    gc_bind() { \(forward); }; \
    gc_watch() { "$@" > "$gc_tmp" 2>/dev/null & gc_q=$!; \
    while kill -0 $gc_q 2>/dev/null; do gc_up || gc_stop $gc_q; sleep 1; done; \
    wait $gc_q; gc_rc=$?; gc_q=; return $gc_rc; }; \
    gc_serve() { [ "$gc_was" = forward-failed ] || gc_note bind; \
    gc_t0=$(date +%s); gc_bind & gc_f=$!; gc_n=0; gc_ino=; gc_end=; gc_next=\(min(5, recheck)); \
    while kill -0 $gc_f 2>/dev/null; do gc_up || { gc_end=parent; break; }; sleep 1; gc_n=$((gc_n + 1)); \
    [ $gc_n -lt $gc_next ] && continue; gc_n=0; \
    gc_watch gc_check || continue; gc_seen=$(cat "$gc_tmp"); \
    case $gc_seen in ino:*) ;; *) continue;; esac; gc_seen=${gc_seen#ino:}; \
    if [ -z "$gc_ino" ]; then [ -n "$gc_seen" ] && { gc_ino=$gc_seen; gc_next=\(recheck); }; \
    elif [ -z "$gc_seen" ]; then gc_end=endpoint-lost; break; \
    elif [ "$gc_seen" != "$gc_ino" ]; then gc_end=endpoint-replaced; break; fi; done; \
    gc_stop $gc_f; wait $gc_f 2>/dev/null; gc_f=; \
    if [ -n "$gc_end" ]; then [ $gc_end = parent ] || gc_note $gc_end; \
    elif [ $(($(date +%s) - gc_t0)) -lt 10 ]; then gc_note forward-failed; \
    else gc_note forward-ended; fi; }; \
    trap 'rm -f "$gc_tmp"' EXIT; \
    trap 'gc_stop "$gc_f"; gc_stop "$gc_q"; exit 0' TERM HUP INT; \

    """
  }

  /// The `ssh -N -R` line itself, with the remote socket path assembled around the
  /// `$H` the pre-dial captured — which is why this is a shell line and not an argv.
  /// Public for the tests that pin the codespace/ssh split of the dial.
  public static func forwardCommandLine(
    for location: RemoteProjectLocation, localSocketPath: String
  )
    -> String
  {
    var argv: [String]
    if location.isCodespace {
      // gh names the destination itself; `-N` and the forward ride through as
      // ssh-flags, past the `--`.
      argv = [GhLocator.executablePath, "codespace", "ssh", "-c", location.host, "--"]
    } else {
      argv = [SSHExecutableResolver.executableURL()?.path ?? "ssh"]
    }
    argv += [
      "-N",
      "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
      "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
    ]
    if !location.isCodespace, let port = location.port { argv += ["-p", String(port)] }
    var quoted =
      argv.map(RemoteProjectLocation.shellQuoted) + [
        "-R",
        "\"$H\""
          + RemoteProjectLocation.shellQuoted("/.graphcode/graphcoded.sock:" + localSocketPath),
      ]
    if !location.isCodespace {
      quoted.append(RemoteProjectLocation.shellQuoted(location.sshDestination))
    }
    return quoted.joined(separator: " ")
  }
}
