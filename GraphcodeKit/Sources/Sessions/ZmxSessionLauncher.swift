import Foundation

/// Starts an unattended node's session — time-based or goal-based — detached, so its
/// loop runs whether or not the app is open. The daemon-side half of
/// `GraphStore.ensureUnattendedSessions`.
///
/// This launches a session and then has nothing more to do with it. It does *not* drive
/// the schedule: the recurrence lives inside the session, expressed in the node's own
/// prompt via the backend's looping skill (see `LoopNode.triggerPrompt`). That split —
/// daemon owns liveness, session owns cadence — is what lets a human attach to a running
/// time-based loop and steer it, which a headless `claude -p` per tick never allowed.
/// A goal-based node's session works the same way; what its opening prompt says is
/// `LoopNode.sessionPrompt`'s business, not this type's.
///
/// The session name is `SurfaceRef(id: node.id).zmxSessionName`, exactly what the app's
/// primary surface attaches to. That shared identity *is* the mechanism: `zmx attach`
/// ignores its command argument when the session already exists (ThirdParty/zmx
/// `src/main.zig`, `ensureSession`), so opening the node joins this very session with its
/// scrollback and live process intact rather than starting a second one.
///
/// Verified against the vendored `zmx` rather than assumed — an earlier version of this
/// staged the prompt in a file for `"$(cat …)"` to expand, which silently fails: `zmx`
/// shell-quotes each argument, so `claude` received the literal `$(cat …)` text as its
/// prompt instead of the prompt itself.
public enum ZmxSessionLauncher {
  /// `zmx kill <name>` is a no-op (with a stderr note) when nothing matches, so this is
  /// safe for a node whose session was never started or has already exited.
  static func killArguments(forNode node: LoopNode) -> [String] {
    ["kill", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName]
  }

  /// `zmx send <name> <text>` types text into a live session — the transport a
  /// `.message` edge rides on (docs/02-graph-of-loops.md#inter-loop-messaging-in-practice).
  /// Returns false when there's no live session to deliver into, so the caller can
  /// report an undelivered message rather than assume it landed.
  static func sendArguments(_ text: String, toNode node: LoopNode) -> [String] {
    // Same newline flattening as a launch prompt, and for the same reason: `zmx`
    // terminates what it types with `\r`, so an embedded newline would truncate the
    // message at the first line.
    let singleLine =
      text
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    return ["send", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, singleLine]
  }

  /// Wraps a backend command in an **interactive login** shell, so it resolves the same
  /// way it would if a human typed it into a terminal.
  ///
  /// `-i` is the load-bearing flag, not decoration. `graphcoded` runs under `launchd` with
  /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, and a developer's real `PATH` is typically set
  /// in `~/.zshrc` — which zsh reads only when *interactive*. A plain `zsh -l -c` sources
  /// `.zprofile`/`.zlogin` and never `.zshrc`, so the command isn't found. And `zmx run`
  /// executes what it's given under **bash**, which can't see `~/.zshrc` at all, so a bare
  /// `claude …` there fails with `command not found` no matter what.
  ///
  /// Arguments ride in after the script as `$@` rather than being interpolated into it.
  /// zsh hands them to the command untouched, so a goal or prompt containing quotes, `;`,
  /// or `$(…)` is one argument and cannot become shell syntax.
  static func loginShellInvocation(
    of command: String, arguments: [String], environment: [String: String] = [:]
  ) -> [String] {
    // `env K=V …` rather than exporting: it scopes the variables to this one process, and
    // keeps the script a single `exec` so the shell doesn't linger as a parent. Values are
    // double-quoted because a project path can contain spaces; the whole script is one
    // argument, which `zmx` shell-quotes before typing it.
    let exports =
      environment.keys.sorted()
      .map { key in "\(key)=\"\(environment[key] ?? "")\" " }
      .joined()
    let prefix = exports.isEmpty ? "" : "env \(exports)"
    // `$0` has to be something, and it shows up in error messages — name it after us.
    return ["/bin/zsh", "-i", "-l", "-c", "exec \(prefix)\(command) \"$@\"", "graphcode"]
      + arguments
  }

  /// `zmx get <name> <key>` reads a per-session label. This is the channel a backend's
  /// own lifecycle hooks report presence through — a Claude Code hook running
  /// `zmx set "$ZMX_SESSION" presence=busy` is what makes a reading `.reported` rather
  /// than inferred. graphcode does not install those hooks itself: that means writing
  /// into the user's own Claude Code settings, which is their call to make, not
  /// something to do behind their back on first launch.
  static func presenceLabelArguments(forNode node: LoopNode) -> [String] {
    ["get", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "presence"]
  }

  /// `zmx get <name> usage` — the token/cost counterpart to the presence label.
  ///
  /// Same arrangement, same honesty constraint: graphcode cannot see inside a running
  /// `claude`, so the only truthful source is the backend reporting into its session's
  /// label store. A Claude Code hook running `zmx set "$ZMX_SESSION" usage=…` is what
  /// populates this. Without one the answer is nil, and the rollup says "not reported"
  /// rather than showing a zero nobody measured.
  static func usageLabelArguments(forNode node: LoopNode) -> [String] {
    ["get", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "usage"]
  }

  static func usage(of node: LoopNode) async -> UsageSample? {
    guard ZmxLocator.isInstalled, await sessionExists(node) else { return nil }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: usageLabelArguments(forNode: node))
    else { return nil }
    let (succeeded, output) = await session.waitCollectingOutput()
    guard succeeded else { return nil }
    return UsageSample.parse(output)
  }

  static func send(_ text: String, to node: LoopNode) async -> Bool {
    guard ZmxLocator.isInstalled, !text.isEmpty else { return false }
    guard await sessionExists(node) else { return false }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: sendArguments(text, toNode: node))
    else { return false }
    return await session.waitUntilFinished()
  }

  /// Reads a session's presence, preferring what the backend reported over what we can
  /// infer. A live session with no label is reported as idle at `.heuristic` confidence
  /// rather than guessed at — docs/04-cli-backends.md asks for the fallback to be
  /// visibly lower-confidence, not dressed up as a fact.
  static func presence(of node: LoopNode) async -> PresenceReading {
    guard ZmxLocator.isInstalled, await sessionExists(node) else { return .absent }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: presenceLabelArguments(forNode: node))
    else { return PresenceReading(presence: .idle, confidence: .heuristic) }

    let (succeeded, output) = await session.waitCollectingOutput()
    guard succeeded, let reported = parsePresenceLabel(output) else {
      return PresenceReading(presence: .idle, confidence: .heuristic)
    }
    return PresenceReading(presence: reported, confidence: .reported)
  }

  /// Labels come back as raw text; anything we don't recognise is treated as no label at
  /// all rather than coerced into the nearest case.
  static func parsePresenceLabel(_ output: String) -> Presence? {
    let trimmed =
      output
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "presence=", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Presence(rawValue: trimmed)
  }

  private static func sessionExists(_ node: LoopNode) async -> Bool {
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: existenceCheckArguments(forNode: node))
    else { return false }
    return await session.waitUntilFinished()
  }

  static func kill(_ node: LoopNode) async {
    guard ZmxLocator.isInstalled else { return }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: killArguments(forNode: node))
    else { return }
    _ = await session.waitUntilFinished()
  }

  /// `zmx get <name>` exits 0 when the session exists and 1 when it doesn't — the check
  /// that stops `ensureUnattendedSessions()` from re-sending a prompt into a loop that's
  /// already running. `zmx run` is *not* idempotent: against a live session it types the
  /// command in again, which would either land as text in the running Claude's input or
  /// queue a second `claude` behind the first.
  static func existenceCheckArguments(forNode node: LoopNode) -> [String] {
    ["get", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName]
  }

  /// The `zmx` argv for a node, or `nil` when there's no prompt to run.
  ///
  /// `zmx run <name> -d <cmd…>` creates the session if it doesn't exist and runs `cmd`
  /// detached. Note `-d` follows the *name*: `zmx run -d <name>` creates a session
  /// literally called `-d`.
  ///
  /// The prompt is passed as its own argument and needs no quoting or staging from us:
  /// `zmx` shell-quotes every argument before typing the command into the session's shell
  /// (`util.shellQuote`, a standard shlex-style single-quote escape), so it reaches
  /// `claude` as exactly one word no matter what quotes, `$(…)`, or `;` it contains.
  static func arguments(forNode node: LoopNode, projectPath: String? = nil) -> [String]? {
    guard let prompt = node.sessionPrompt, !prompt.isEmpty else { return nil }
    // A backend graphcode can't launch has no argv. `canHost` already refuses to create
    // such a node, so this is the belt to that braces — but silently starting the wrong
    // agent is the failure it exists to prevent, so it's worth both.
    guard let executable = node.backend.executableName else { return nil }
    // CR/LF are the one thing quoting can't save us from: zmx terminates the command it
    // types with `\r`, and the PTY's line discipline would accept the line early at an
    // embedded one, truncating the prompt. Prompts come from a single-line text field, so
    // this only ever fires on a paste.
    let singleLine = Self.flattened(prompt)
    // What the session is told about the graph it belongs to, so a loop can fan work out
    // into more loops when the work genuinely calls for it (`SessionBriefing`). Written to
    // a file and passed by *path*: the prose itself is far longer than a typed command
    // line can carry — see `SessionBriefing` for the failure that taught us so.
    // Read per launch, not cached: changing a setting in the app then applies to the very
    // next loop the daemon starts, with nothing to restart.
    let settings = GraphcodeSettingsStore.load()
    let briefingFile =
      settings.briefsSessionsAboutTheGraph
      ? SessionBriefing.write(projectPath: projectPath) : nil
    // Both the executable and the shape of its arguments come from the node's backend —
    // `claude` takes its prompt positionally and its briefing via `--append-system-prompt`,
    // `copilot` takes both together as `--interactive <prompt>`. Model tier is applied
    // here rather than baked into the prompt: it's the orchestrator's scheduling decision
    // (docs/05-orchestrator.md#responsibilities item 7).
    let arguments = node.backend.launchArguments(
      prompt: singleLine, tier: node.effectiveModelTier, briefingFile: briefingFile,
      settings: settings)
    let command =
      [
        "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      ]
      + Self.loginShellInvocation(
        of: executable, arguments: arguments,
        environment: Self.environment(forBackend: node.backend, briefingFile: briefingFile))

    // `zmx` types this command into the session's shell, and a tty in canonical mode
    // discards everything past `MAX_CANON` (1024 bytes on macOS). Overrunning it does not
    // fail loudly: the tail is dropped mid-argument and the shell waits forever at a
    // continuation prompt for a quote that was eaten. Dropping the briefing is the one
    // safe thing to give up — the prompt is the human's, and a loop that launches without
    // its briefing merely can't fan out, where a truncated one does nothing at all.
    guard Self.fitsInATypedCommandLine(command) else {
      let unbriefed = node.backend.launchArguments(
        prompt: singleLine, tier: node.effectiveModelTier, settings: settings)
      return [
        "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      ] + Self.loginShellInvocation(of: executable, arguments: unbriefed)
    }
    return command
  }

  /// Environment a session needs beyond what its shell provides. Only Copilot uses one:
  /// it discovers custom instructions by searching directories, and this is how it is told
  /// about the one holding this project's briefing (`SessionBriefing`).
  static func environment(forBackend backend: CLISessionBackendKind, briefingFile: URL?)
    -> [String: String]
  {
    guard backend == .copilotCLI, let briefingFile else { return [:] }
    return [
      SessionBriefing.copilotInstructionsDirectoryVariable:
        briefingFile.deletingLastPathComponent().path
    ]
  }

  /// Whether the assembled command survives being typed into a terminal. Budgeted well
  /// under `MAX_CANON` because `zmx` shell-quotes every argument before typing it, which
  /// only ever makes the line longer than what's measured here.
  static func fitsInATypedCommandLine(_ command: [String]) -> Bool {
    command.reduce(0) { $0 + $1.utf8.count + 3 } <= maximumTypedCommandBytes
  }

  /// 1024 is the kernel's limit; this leaves room for quoting and for `zmx`'s own framing.
  static let maximumTypedCommandBytes = 800

  /// Newlines are the one thing quoting can't save us from — see `arguments(forNode:)`.
  private static func flattened(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }

  /// Where an unattended session should open, mirroring what the app already does for a
  /// loop a human opens (`LoopWorkspaceView.surfaceView`): the node's own worktree if it
  /// has one, otherwise the project it belongs to.
  ///
  /// Falling through to `nil` means inheriting the caller's directory, and `graphcoded`'s
  /// is `/` under launchd — which is how an unattended loop ended up running somewhere
  /// unrelated to the project it was created in. `projectPath` is checked for being a real
  /// directory rather than trusted: the global Orchestrator Graph's path is the reserved
  /// URI `graphcode://global`, which names no directory at all.
  static func workingDirectory(forNode node: LoopNode, projectPath: String?) -> String? {
    if let worktree = node.worktreeBinding?.worktreePath { return worktree }
    guard let projectPath else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return projectPath
  }

  static func start(_ node: LoopNode, projectPath: String? = nil) async {
    guard ZmxLocator.isInstalled else { return }
    guard let arguments = arguments(forNode: node, projectPath: projectPath) else { return }

    do {
      // Create only. A session that already exists is left strictly alone — it's either
      // the loop still running (re-sending would corrupt it) or one whose Claude has
      // exited, which resolved the node and is a deliberate end state, not something to
      // silently restart behind the human's back.
      let existing = try PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: existenceCheckArguments(forNode: node))
      guard await !existing.waitUntilFinished() else { return }

      let launch = try PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: arguments,
        workingDirectory: workingDirectory(forNode: node, projectPath: projectPath))
      // `zmx run -d` returns as soon as it has handed the command to the session daemon,
      // which then outlives it. Waiting keeps this short-lived launcher process (and its
      // PTY) alive until then rather than tearing it down mid-spawn.
      _ = await launch.waitUntilFinished()
    } catch {
      // Nothing useful to do from here: the daemon has no UI, and a node whose session
      // failed to start still shows its real (unchanged) state in every client. The
      // human sees an empty terminal when they open it, and reopening retries.
      return
    }
  }
}
