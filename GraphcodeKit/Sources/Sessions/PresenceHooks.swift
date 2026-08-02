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

  /// The settings JSON for a backend, or `nil` when it has no hooks to configure.
  /// Serialized rather than interpolated so a support directory containing a quote is a
  /// path, not a syntax error.
  public static func json(forBackend backend: CLISessionBackendKind, zmxPath: String) -> String? {
    guard let events = events(forBackend: backend) else { return nil }
    let hooks = events.reduce(into: [String: [Matcher]]()) { result, event in
      result[event.0] = [Matcher(hooks: [Command(command: report(event.1, zmxPath: zmxPath))])]
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
