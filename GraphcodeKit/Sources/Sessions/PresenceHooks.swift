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

  /// The `PreToolUse` reporter, kept as a file next to the settings that name it: it is a
  /// dozen lines of `case` and `sed`, and `zmx` types a launch command into a tty capped
  /// at `MAX_CANON` — the same reason the settings themselves travel by path.
  public static var activityScriptFile: URL {
    directory.appendingPathComponent("activity.sh")
  }

  /// The `Stop`/`SessionEnd` usage reporter, a file for the same `MAX_CANON` reason.
  public static var usageScriptFile: URL {
    directory.appendingPathComponent("usage.sh")
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
  ///
  /// `clearingActivity` drops the activity label in the same write, and every event
  /// except `PreToolUse` asks for it. Only a tool call knows what a session is doing; the
  /// moment it answers, stops, or ends, the last thing it was doing is a sentence about
  /// the past, and a card still reading "editing LoopNode.swift" under an IDLE pill is
  /// exactly the stale claim the presence work removed from the pill itself.
  static func report(_ presence: Presence, zmxPath: String, clearingActivity: Bool = false)
    -> String
  {
    // `k=` is how `zmx` removes a label, so this is one process, not two.
    let labels = "presence=\(presence.rawValue)" + (clearingActivity ? " activity=" : "")
    return "if [ -n \"$ZMX_SESSION\" ]; then \(singleQuoted(zmxPath)) set \"$ZMX_SESSION\" "
      + "\(labels) >/dev/null 2>&1; fi; exit 0"
  }

  /// The `PreToolUse` body that runs `activityScript`, guarded so a missing file is a
  /// no-op rather than a hook error printed on the human's own turn.
  ///
  /// Left as a second command beside the presence report rather than folded into the
  /// script: presence is the signal the pill, the attention rollup and `MessageBus` all
  /// key off, and it must not stop being reported because a `sed` in the reporter of a
  /// nicety went wrong.
  static func reportActivity(scriptPath: String) -> String {
    "if [ -r \(scriptPath) ]; then /bin/sh \(scriptPath); fi; exit 0"
  }

  /// The `Stop`/`SessionEnd` body that runs `usageScript`, guarded the same way and for
  /// the same reasons as `reportActivity` — and kept beside the presence report rather
  /// than folded in, so token accounting going wrong can never stop presence being
  /// reported.
  static func reportUsage(scriptPath: String) -> String {
    "if [ -r \(scriptPath) ]; then /bin/sh \(scriptPath); fi; exit 0"
  }

  /// This session's cumulative token spend, summed from its own transcript — the write
  /// half of `LoopNode.usage`, which shipped with a reader (`ZmxSessionLauncher.usage`),
  /// a rollup, a cost panel, and — once budgets landed — an *enforcer*, and nothing at
  /// all that wrote it. `UsageSample`'s docs said "install a hook that runs `zmx set
  /// usage=inputTokens=…`", and no such hook could even work: a `zmx` label value takes
  /// only `[A-Za-z0-9._-]`, so the documented format was unstorable. This writes the
  /// `key.value_key.value` form `UsageSample.parse` reads for exactly that reason.
  ///
  /// The transcript is the source because it is the only thing on disk the backend
  /// itself wrote per turn: every assistant record carries its `usage` block, and the
  /// literal `"input_tokens":` match cannot collide with the `cache_…_input_tokens`
  /// keys (their preceding byte is `_`, not `"`), which are summed separately below —
  /// a budget is spent by what the API metered, cache reads included.
  ///
  /// **One count per message, not per line.** Claude Code writes one JSONL record per
  /// content block — a turn with text plus three tool calls is four records — and
  /// every record repeats the same message-level `usage`. A naive line-sum therefore
  /// overcounted roughly 2× (measured on a real transcript: 1,524,855 vs 768,566 after
  /// dedup), tripping budgets at half their stated bound. Records dedup on the
  /// message `id` (`"id":"msg_…"`), and a record with a usage block but no such id —
  /// not a shape Claude Code writes today — still counts rather than silently
  /// vanishing.
  ///
  /// Runs on `Stop` — once per turn, when the spend just changed — never per tool call:
  /// it reads the whole transcript, and `PreToolUse` frequency would price it wrong.
  /// Cannot fail and cannot block, same contract as every hook here: every path exits 0.
  static func usageScript(zmxPath: String) -> String {
    """
    # Written by graphcode. Reports this session's token spend, for the usage rollup
    # and goal budgets.
    [ -n "$ZMX_SESSION" ] || exit 0
    payload=$(head -c 4096 | tr '\\n' ' ')
    transcript=$(printf '%s' "$payload" |
      sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
    [ -r "$transcript" ] || exit 0
    label=$(awk '
      function grab(key,    s, t, n) {
        n = 0
        s = $0
        while (match(s, key "[0-9]+")) {
          t = substr(s, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", t)
          n += t
          s = substr(s, RSTART + RLENGTH)
        }
        return n
      }
      {
        if (match($0, /"id":"msg_[A-Za-z0-9]+"/)) {
          id = substr($0, RSTART, RLENGTH)
          if (seen[id]++) next
        }
        input += grab("\\"input_tokens\\":")
        input += grab("\\"cache_creation_input_tokens\\":")
        input += grab("\\"cache_read_input_tokens\\":")
        output += grab("\\"output_tokens\\":")
      }
      END { if (input + output > 0) printf "input.%d_output.%d", input, output }
    ' "$transcript" 2>/dev/null)
    [ -n "$label" ] || exit 0
    \(singleQuoted(zmxPath)) set "$ZMX_SESSION" "usage=$label" >/dev/null 2>&1
    exit 0
    """
  }

  /// What the session is doing, in its own words, derived from the `PreToolUse` payload
  /// on stdin — `"editing LoopNode.swift"`, `"running make check"`.
  ///
  /// This is the write half of `LoopNode.activity`, which shipped with a reader, a card
  /// row and a fallback, and nothing at all that wrote it. Without it every busy loop's
  /// card said RUNNING over the sentence it was created with, however long ago that was
  /// and whatever it had moved on to since.
  ///
  /// **Why the value is encoded.** A `zmx` label store is `k=v` pairs separated by spaces
  /// and its parser takes only `[A-Za-z0-9._-]` in a value, so `activity=editing Loop.swift`
  /// silently stores `editing`. Every disallowed byte becomes a space, every space becomes
  /// `_20` and every literal underscore `_5F` — percent-encoding with `_` for `%`, since
  /// `%` is no more allowed than a space is. `ZmxSessionLauncher.decodedActivity` reads it
  /// back.
  ///
  /// **It cannot fail and it cannot block.** A `PreToolUse` hook exiting 2 blocks the tool
  /// call it was only trying to describe, and any other non-zero exit prints a hook error
  /// over the human's session. Every path here ends `exit 0`. The payload is read with
  /// `head -c` for the same reason: a `Write` of a large file arrives here in full, and
  /// this is not the place to spend it.
  static func activityScript(zmxPath: String) -> String {
    """
    # Written by graphcode. Reports what this session is doing, for its card in the graph.
    [ -n "$ZMX_SESSION" ] || exit 0
    payload=$(head -c 4096 | tr '\\n' ' ')
    field() {
      printf '%s' "$payload" |
        sed -n "s/.*\\"$1\\"[[:space:]]*:[[:space:]]*\\"\\([^\\"]*\\)\\".*/\\1/p"
    }
    tool=$(field tool_name)
    case "$tool" in
      Edit|Write|MultiEdit|NotebookEdit) target=$(field file_path); phrase="editing ${target##*/}" ;;
      Read) target=$(field file_path); phrase="reading ${target##*/}" ;;
      Bash|BashOutput) phrase="running $(field command)" ;;
      Grep) phrase="searching for $(field pattern)" ;;
      Glob) phrase="looking for $(field pattern)" ;;
      WebSearch) phrase="searching the web for $(field query)" ;;
      WebFetch) target=$(field url); target=${target#*//}; phrase="reading ${target%%/*}" ;;
      Task|Agent) phrase="delegating $(field description)" ;;
      Skill) phrase="running the $(field skill) skill" ;;
      TodoWrite|TaskCreate|TaskUpdate) phrase="planning" ;;
      mcp__*) phrase="using ${tool##*__}" ;;
      "") phrase="" ;;
      *) phrase="using $tool" ;;
    esac
    encoded=$(printf '%s' "$phrase" | cut -c1-64 |
      sed 's/_/_5F/g' | tr -c 'A-Za-z0-9._-' ' ' | tr -s ' ' |
      sed 's/^ *//; s/ *$//; s/ /_20/g')
    \(singleQuoted(zmxPath)) set "$ZMX_SESSION" "activity=$encoded" >/dev/null 2>&1
    exit 0
    """
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
  /// The pointer is overwritten every session start, and the `.history` line beside it
  /// is what makes that recoverable: `<epoch> <session-id> <cwd>`, appended and never
  /// rewritten. See `SessionIDStore.historyFile` for the failure that motivated it.
  /// Written before the pointer so a history line can never be missing for an ID the
  /// pointer already names.
  static func captureSessionID(sessionsDirectory: String) -> String {
    "if [ -n \"$ZMX_SESSION\" ] && [ -n \"$CLAUDE_CODE_SESSION_ID\" ]; then "
      + "node_id=\"${ZMX_SESSION#\(SurfaceRef.zmxSessionPrefix)}\"; "
      + "mkdir -p \(sessionsDirectory); "
      + "printf '%s %s %s\\n' \"$(date +%s)\" \"$CLAUDE_CODE_SESSION_ID\" \"$PWD\" "
      + ">> \(sessionsDirectory)/\"$node_id\".history 2>/dev/null; "
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

  /// Where `activityScript` lands, in the same two shapes and for the same reason.
  static var localActivityScriptExpression: String {
    singleQuoted(activityScriptFile.path)
  }

  public static let remoteActivityScriptExpression = "\"$HOME/.graphcode/hooks/activity.sh\""

  /// Where `usageScript` lands, in the same two shapes again.
  static var localUsageScriptExpression: String {
    singleQuoted(usageScriptFile.path)
  }

  public static let remoteUsageScriptExpression = "\"$HOME/.graphcode/hooks/usage.sh\""

  /// The remote twin of `SessionIDStore.file(forNodeID:)` — the file the remote
  /// `SessionStart` hook wrote, as a shell expression the ensure dial can `cat`.
  ///
  /// Composed from `remoteSessionsExpression` rather than restated: writer and reader
  /// drifting apart would not fail loudly, it would make every remote resume fall
  /// silently through to the opening prompt — the bug this whole path exists to end. The
  /// file name matches what `captureSessionID` derives from `$ZMX_SESSION` for the same
  /// reason it takes the prefix from `SurfaceRef`.
  public static func remoteSessionIDExpression(forNodeID nodeID: UUID) -> String {
    "\(remoteSessionsExpression)/\"\(nodeID.uuidString).id\""
  }

  /// The settings JSON for a backend, or `nil` when it has no hooks to configure.
  /// Serialized rather than interpolated so a support directory containing a quote is a
  /// path, not a syntax error.
  public static func json(
    forBackend backend: CLISessionBackendKind, zmxPath: String,
    sessionsDirectory: String? = nil, activityScriptPath: String? = nil,
    usageScriptPath: String? = nil
  ) -> String? {
    guard let events = events(forBackend: backend) else { return nil }
    let sessions = sessionsDirectory ?? localSessionsExpression
    let script = activityScriptPath ?? localActivityScriptExpression
    let usage = usageScriptPath ?? localUsageScriptExpression
    let hooks = events.reduce(into: [String: [Matcher]]()) { result, event in
      let isToolUse = event.0 == "PreToolUse"
      var commands = [
        Command(command: report(event.1, zmxPath: zmxPath, clearingActivity: !isToolUse))
      ]
      if isToolUse && backend == .claudeCode {
        commands.append(Command(command: reportActivity(scriptPath: script)))
      }
      if event.0 == "SessionStart" && backend == .claudeCode {
        commands.append(Command(command: captureSessionID(sessionsDirectory: sessions)))
      }
      // Turn end and session end are when the spend just changed and the session can
      // afford a transcript read — never per tool call.
      if (event.0 == "Stop" || event.0 == "SessionEnd") && backend == .claudeCode {
        commands.append(Command(command: reportUsage(scriptPath: usage)))
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
      // Best-effort, and deliberately not part of the `do`: the settings must still be
      // written if this fails, because presence is the signal that matters and the hook
      // that runs this file checks it is readable first.
      try? activityScript(zmxPath: ZmxLocator.binaryURL.path)
        .write(to: activityScriptFile, atomically: true, encoding: .utf8)
      try? usageScript(zmxPath: ZmxLocator.binaryURL.path)
        .write(to: usageScriptFile, atomically: true, encoding: .utf8)
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
        sessionsDirectory: remoteSessionsExpression,
        activityScriptPath: remoteActivityScriptExpression,
        usageScriptPath: remoteUsageScriptExpression)
    else { return nil }
    // `|| true` so both call sites can chain it with `&&` — a failed write must never
    // block the launch it precedes. The reporters go first: the settings that name them
    // are what makes them run, and a host that takes one write and not the other should
    // fail towards a hook file pointing at a script that is already there.
    return "{ mkdir -p \"$HOME/.graphcode/hooks\""
      + " && printf '%s' \(singleQuoted(activityScript(zmxPath: "zmx")))"
      + " > \(remoteActivityScriptExpression)"
      + " && printf '%s' \(singleQuoted(usageScript(zmxPath: "zmx")))"
      + " > \(remoteUsageScriptExpression)"
      + " && printf '%s' \(singleQuoted(json))"
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
