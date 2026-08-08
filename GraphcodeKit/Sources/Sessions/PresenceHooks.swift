import Foundation

/// The lifecycle hooks a backend runs to report what its session is doing, and the file
/// they are handed to it in.
///
/// This is the write half of a channel that only ever had a reader.
/// `ZmxSessionLauncher.presence(of:)` has always known how to read `zmx get <session>
/// presence`, but nothing wrote that label, so every reading fell through to
/// `.idle`/`.heuristic` and `LoopState` was the only signal any surface had. A goal loop
/// is `.running` from creation until something resolves it, so its card read RUNNING
/// whether its agent was working or had finished an hour ago — which is the complaint
/// this exists to answer, not a cosmetic one: `.running` is also what the attention
/// rollup and `MessageBus.deliverability` key off.
///
/// **graphcode writes its own settings file rather than editing the human's.** The
/// obvious route — hooks in `~/.claude/settings.json` — is a file people hand-edit and
/// commit, and `ZmxSessionLauncher`'s note that "graphcode does not install those hooks
/// itself" was really a refusal to write there. `claude --settings <file>` loads an
/// *additional* source, which makes the question moot: the hooks live under
/// `~/.graphcode/` and apply to exactly the sessions graphcode launches.
public enum PresenceHooks {
  /// Written hook files live here, one per backend that has a hook mechanism.
  public static var directory: URL {
    SupportDirectory.url.appendingPathComponent("hooks", isDirectory: true)
  }

  public static func file(forBackend backend: CLISessionBackendKind) -> URL {
    directory.appendingPathComponent("\(backend.rawValue).json")
  }

  /// Which of a backend's lifecycle events mean what, in the backend's own event names.
  ///
  /// `nil` for a backend with no hook mechanism at all, which is the honest answer for
  /// Copilot — its presence has to come from somewhere else entirely rather than from a
  /// hook file it would ignore.
  ///
  /// `SubagentStop` is deliberately absent from Claude Code's list: it fires when a
  /// *sub*-agent finishes while the main agent is still working, so reporting idle there
  /// would blank the card in the middle of a fan-out. `PreToolUse` is there for the
  /// opposite reason — a loop woken by its own `/loop` or `/schedule` never submits a
  /// user prompt, so without it a self-driving loop would stay idle through work it is
  /// visibly doing.
  static func events(forBackend backend: CLISessionBackendKind) -> [(String, Presence)]? {
    switch backend {
    case .claudeCode:
      return [
        ("SessionStart", .busy),
        ("UserPromptSubmit", .busy),
        ("PreToolUse", .busy),
        ("Notification", .awaitingInput),
        ("Stop", .idle),
        ("SessionEnd", .absent),
      ]
    case .copilotCLI, .codex:
      return nil
    }
  }

  /// One hook body: report a presence, and never fail.
  ///
  /// `exit 0` is load-bearing rather than tidy — Claude Code reads a hook's exit status,
  /// and a non-zero one from `Stop` blocks the very stop it was reporting. The
  /// `$ZMX_SESSION` guard covers the case where this file reaches a session graphcode
  /// didn't start: there is no session store to write into, and `zmx set` against a name
  /// that doesn't exist is an error a human would see on their own terminal.
  static func report(_ presence: Presence, zmxPath: String) -> String {
    "if [ -n \"$ZMX_SESSION\" ]; then \(singleQuoted(zmxPath)) set \"$ZMX_SESSION\" "
      + "presence=\(presence.rawValue) >/dev/null 2>&1; fi; exit 0"
  }

  /// Captures Claude Code's session ID for `--resume` after a reboot.
  ///
  /// `$CLAUDE_CODE_SESSION_ID` is set by Claude Code in its own process environment, so
  /// every hook script inherits it. The node UUID is extracted from `$ZMX_SESSION`
  /// (`graphcode-<UUID>`), and the ID is written to the `SessionIDStore` path. Silently
  /// skipped when either variable is absent — a session graphcode didn't start, or a
  /// Claude Code version that doesn't export its session ID.
  ///
  /// `sessionsDirectory` is shell *text*, not a path, for the same reason
  /// `remotePathExpression` is one: a hook that runs on another machine has to name that
  /// machine's home directory, and only a shell there can expand it. A hook file carrying
  /// this Mac's `/Users/<me>/.graphcode` wrote nothing at all on a Codespace, where
  /// `/Users` doesn't exist and the agent user can't create it.
  static func captureSessionID(sessionsDirectory: String) -> String {
    "if [ -n \"$ZMX_SESSION\" ] && [ -n \"$CLAUDE_CODE_SESSION_ID\" ]; then "
      + "node_id=\"${ZMX_SESSION#\(SurfaceRef.zmxSessionPrefix)}\"; "
      + "mkdir -p \(sessionsDirectory); "
      + "printf '%s' \"$CLAUDE_CODE_SESSION_ID\" > \(sessionsDirectory)/\"$node_id\".id; "
      + "fi; exit 0"
  }

  /// Where `captureSessionID` writes, as the shell text each side needs: a quoted
  /// absolute path locally (the `SessionIDStore` directory), a `$HOME` expression
  /// remotely.
  static var localSessionsExpression: String {
    singleQuoted(SupportDirectory.url.appendingPathComponent("sessions", isDirectory: true).path)
  }

  public static let remoteSessionsExpression = "\"$HOME/.graphcode/sessions\""

  /// The remote twin of `SessionIDStore.file(forNodeID:)` — the file the remote
  /// `SessionStart` hook wrote, as a shell expression the ensure dial can `cat`. The
  /// name has to match what `captureSessionID` derives from `$ZMX_SESSION`, so both
  /// come from `SurfaceRef`.
  public static func remoteSessionIDExpression(forNodeID nodeID: UUID) -> String {
    "\"$HOME/.graphcode/sessions/\(nodeID.uuidString).id\""
  }

  /// The settings JSON for a backend, or `nil` when it has no hooks to configure.
  /// Serialized rather than interpolated so a support directory containing a quote is a
  /// path, not a syntax error.
  public static func json(
    forBackend backend: CLISessionBackendKind, zmxPath: String,
    sessionsDirectory: String? = nil
  ) -> String? {
    guard let events = events(forBackend: backend) else { return nil }
    let sessions = sessionsDirectory ?? localSessionsExpression
    let hooks = events.reduce(into: [String: [Matcher]]()) { result, event in
      var commands = [Command(command: report(event.1, zmxPath: zmxPath))]
      if event.0 == "SessionStart" && backend == .claudeCode {
        commands.append(Command(command: captureSessionID(sessionsDirectory: sessions)))
      }
      result[event.0] = [Matcher(hooks: commands)]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(Settings(hooks: hooks)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Writes the hook file for `backend` and returns where it landed, or `nil` when the
  /// backend has no hooks, `zmx` isn't installed to report through, or writing failed.
  ///
  /// Rewritten per launch for the same reason `SessionBriefing.write` is: it costs one
  /// small write, and it means an upgraded graphcode's hooks apply to the next session
  /// rather than to the next machine that happens to have no file yet.
  public static func write(forBackend backend: CLISessionBackendKind) -> URL? {
    guard ZmxLocator.isInstalled,
      let json = json(forBackend: backend, zmxPath: ZmxLocator.binaryURL.path)
    else { return nil }
    let url = file(forBackend: backend)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try json.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      // A session with no hooks is the pre-hook behaviour: presence falls back to the
      // heuristic. Failing the launch over a reporting channel would trade a weaker
      // signal for no loop at all.
      return nil
    }
  }

  // MARK: - Remote sessions

  /// Where the hooks land on a remote host — a `$HOME` expression rather than a path,
  /// because only a shell on that machine knows the home directory, and Claude Code is
  /// handed the flag inside a shell script exactly so this expands there
  /// (`ZmxSessionLauncher.loginShellInvocation`'s `scriptSuffix`).
  public static let remotePathExpression = "$HOME/.graphcode/hooks/claude-code.json"

  /// The shell fragment a remote ensure/attach runs before creating the session: writes
  /// the same hooks the local launcher writes, on the host where they will run — with
  /// the captured session ID landing in *that* host's `~/.graphcode/sessions`, which is
  /// where `ZmxSessionLauncher.remoteEnsureInvocation` reads it back to resume. `zmx` by
  /// bare name — the hook's `sh` inherits the agent's `PATH`, which came from the
  /// interactive login shell that found `zmx` in the first place (the same resolution
  /// the connection form validated). Errors are squelched: a host that can't take the
  /// write gets the pre-hook behaviour, a heuristic presence, not a failed launch. The
  /// launch still passes `--settings`; if the file has never once been written the
  /// launch fails visibly in the loop's own terminal, which beats silently running an
  /// unobservable session.
  public static func remoteWriteFragment() -> String? {
    guard
      let json = json(
        forBackend: .claudeCode, zmxPath: "zmx",
        sessionsDirectory: remoteSessionsExpression)
    else { return nil }
    // `|| true` so both call sites can chain it with `&&` — a failed write must never
    // block the launch it precedes.
    return "{ mkdir -p \"$HOME/.graphcode/hooks\" && printf '%s' \(singleQuoted(json))"
      + " > \"\(remotePathExpression)\"; } 2>/dev/null || true"
  }

  /// Codex's `-c notify=…` override: the program Codex runs when a turn completes.
  ///
  /// Codex is the third shape of the same problem. It has no `--settings` to layer hooks
  /// into (its `hooks.json` mechanism exists — `hooks.managed_dir` is a real key — but its
  /// file schema is undocumented, a hand-built one was measured *not* to fire, and
  /// `BackendCapabilities` is explicit that a capability claimed on a hunch is the thing
  /// `isSpiked` exists to prevent). It has no `--name` to make its rollout log findable
  /// either. What it does have is `notify`, which fires on `agent-turn-complete` — exactly
  /// the edge a loop that has answered and gone quiet crosses, and exactly the one the
  /// graph was missing.
  ///
  /// Validated as a real key rather than assumed: `codex --strict-config` rejects an
  /// invented field outright ("unknown configuration field") and accepts this one.
  ///
  /// The value is TOML, parsed by Codex out of one argv element. Codex appends its event
  /// JSON as a further argument, which `sh -c` puts in `$0` and this ignores.
  public static func codexNotifyOverride(zmxPath: String) -> String {
    let script =
      "\(singleQuoted(zmxPath)) set \"$ZMX_SESSION\" presence=idle >/dev/null 2>&1; exit 0"
    return "notify=[\"/bin/sh\",\"-c\",\(tomlString(script))]"
  }

  /// A TOML basic string. Only the two escapes this can actually produce are handled,
  /// because the only input is a path and a fixed script.
  static func tomlString(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  /// shlex-style quoting, matching what `zmx` does to every argument it types. Public
  /// because `GhosttyTerminalView` assembles a shell *string* where the daemon assembles
  /// an argv array, so it has to do this quoting itself.
  public static func singleQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private struct Command: Encodable {
    let type = "command"
    let command: String
  }

  private struct Matcher: Encodable {
    let hooks: [Command]
  }

  private struct Settings: Encodable {
    let hooks: [String: [Matcher]]
  }
}
