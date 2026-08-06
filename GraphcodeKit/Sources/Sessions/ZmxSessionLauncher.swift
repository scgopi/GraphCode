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
  /// `scriptSuffix` is extra command line that must be *evaluated by this shell* rather
  /// than ride through `"$@"`: positional arguments pass untouched, so a `$HOME` in one
  /// stays a literal dollar sign forever. The remote hooks flag needs the expansion —
  /// the path is on a machine whose home directory only that shell knows.
  static func loginShellInvocation(
    of command: String, arguments: [String], environment: [String: String] = [:],
    scriptSuffix: String = ""
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
    return [
      "/bin/zsh", "-i", "-l", "-c", "exec \(prefix)\(command) \"$@\"\(scriptSuffix)",
      "graphcode",
    ] + arguments
  }

  /// `zmx get <name> <key>` reads a per-session label. This is the channel a backend's
  /// own lifecycle hooks report presence through — a Claude Code hook running
  /// `zmx set "$ZMX_SESSION" presence=busy` is what makes a reading `.reported` rather
  /// than inferred.
  ///
  /// graphcode writes those hooks (`PresenceHooks`) but still doesn't touch the user's
  /// own `~/.claude/settings.json`, which is theirs to keep: `claude --settings <file>`
  /// loads an additional source, so the hooks live under `~/.graphcode/` and reach
  /// exactly the sessions graphcode starts.
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

  /// `zmx get <name> activity` — the third label on the same channel as presence and
  /// usage, and under the same constraint: a hook writes it or nothing does.
  static func activityLabelArguments(forNode node: LoopNode) -> [String] {
    ["get", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "activity"]
  }

  /// What the session says it is doing, or `nil` when nothing reported.
  ///
  /// Trimmed and truncated here rather than at the card: a label is whatever a hook
  /// wrote, and one that arrives as a paragraph would otherwise reach the graph, the
  /// broadcast, and every card's one-line row.
  static func activity(of node: LoopNode, projectPath: String? = nil) async -> String? {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      guard case .live(let label) = await remoteStatus(of: node, label: "activity", at: remote),
        let label
      else { return nil }
      return parseActivityLabel(label)
    }
    guard ZmxLocator.isInstalled, await sessionExists(node) else { return nil }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: activityLabelArguments(forNode: node))
    else { return nil }
    let (succeeded, output) = await session.waitCollectingOutput()
    guard succeeded else { return nil }
    return parseActivityLabel(output)
  }

  static func parseActivityLabel(_ output: String) -> String? {
    let collapsed =
      output
      .replacingOccurrences(of: "activity=", with: "")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    return String(collapsed.prefix(maxActivityLength))
  }

  /// One line of a 250pt card, at 10.5pt mono. Past this a label is not being read, it
  /// is being truncated somewhere further down where nobody chose the cut.
  static let maxActivityLength = 80

  static func usage(of node: LoopNode, projectPath: String? = nil) async -> UsageSample? {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      guard case .live(let label) = await remoteStatus(of: node, label: "usage", at: remote),
        let label
      else { return nil }
      return UsageSample.parse(label)
    }
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

  /// The Enter keystroke, sent as its own `zmx send` after the text.
  ///
  /// `zmx send` writes exactly its payload to the PTY and nothing more — submission is
  /// explicitly the caller's job (ThirdParty/zmx `src/main.zig`, `handleSend`). And the
  /// `\r` cannot ride in the same payload as the text: an agent TUI's paste heuristic
  /// treats text-plus-CR arriving in one chunk as a *pasted newline*, so the message
  /// landed in the composer, rendered, and sat there unsent — which is exactly how the
  /// bug was found, a `[graphcode]` message blinking in a Claude input box. A separate
  /// send, after the composer has had a beat to settle, reads as a keystroke.
  static func submitArguments(forNode node: LoopNode) -> [String] {
    ["send", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "\r"]
  }

  /// How long the composer gets between the text and the Enter. Generous rather than
  /// minimal: this path is a message between loops, where an extra beat costs nothing
  /// and a lost message costs the whole point of sending it.
  static let submitDelay: Duration = .milliseconds(400)

  static func send(_ text: String, to node: LoopNode, projectPath: String? = nil) async -> Bool {
    // A remote loop's session lives in another host's zmx daemon — the local socket has
    // never heard of it, so a local send was a guaranteed failure (observed as every
    // message to a remote loop landing in "staged to its memory"). The send rides ssh
    // instead, same as the launch does.
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      return await sendRemote(text, to: node, at: remote)
    }
    guard ZmxLocator.isInstalled, !text.isEmpty else { return false }
    guard await sessionExists(node) else { return false }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: sendArguments(text, toNode: node))
    else { return false }
    guard await session.waitUntilFinished() else { return false }
    // Typed is not sent: submit as a second, separate keystroke — see `submitArguments`.
    try? await Task.sleep(for: submitDelay)
    guard
      let submit = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: submitArguments(forNode: node))
    else { return false }
    let delivered = await submit.waitUntilFinished()
    // Typing into a Codex session starts a turn, and Codex has no way to say so itself.
    // Clearing the label here is that missing edge — see `codexPresence`.
    if delivered, node.backend == .codex { await clearPresenceLabel(of: node) }
    return delivered
  }

  /// Reads a session's presence, preferring what the backend reported over what we can
  /// infer. A live session with no label is reported as idle at `.heuristic` confidence
  /// rather than guessed at — docs/04-cli-backends.md asks for the fallback to be
  /// visibly lower-confidence, not dressed up as a fact.
  ///
  /// A remote loop's session is asked over ssh — the local zmx has never heard of it,
  /// and asking it anyway is why every remote loop used to read IDLE forever.
  static func presence(of node: LoopNode, projectPath: String? = nil) async -> PresenceReading {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      return await remotePresence(
        of: node, at: remote,
        liveWithoutLabel: PresenceReading(presence: .idle, confidence: .heuristic))
    }
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

  /// Codex's presence, which is read the other way up from everyone else's.
  ///
  /// Codex reports exactly one edge — `notify` fires on `agent-turn-complete`, writing
  /// `presence=idle` (`PresenceHooks.codexNotifyOverride`). Nothing reports the *start* of
  /// a turn, so a missing label on a live session is read as busy rather than as no
  /// information.
  ///
  /// That inversion is sound for this backend specifically, and only this one. A Codex
  /// turn begins in exactly two ways: graphcode launched the session, or graphcode typed
  /// into it — and the second clears the label on the way past (see `send`). It cannot
  /// begin any other way, because `BackendCapabilities` records Codex as having no
  /// in-session recurrence: unlike Claude Code's `/loop`, its agent has no way to wake
  /// itself. So "live, and has not reported finishing a turn" really does mean mid-turn.
  ///
  /// Reported at `.scanned` rather than `.reported` for the half graphcode inferred. If
  /// `notify` never fires — a Codex too old for it, an override the user has replaced —
  /// this degrades to permanently busy, which is the failure it was built to fix. That is
  /// the one thing worth watching when this backend is next spiked against a live login.
  static func codexPresence(of node: LoopNode, projectPath: String? = nil) async
    -> PresenceReading
  {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      return await remotePresence(
        of: node, at: remote,
        liveWithoutLabel: PresenceReading(presence: .busy, confidence: .scanned))
    }
    guard ZmxLocator.isInstalled, await sessionExists(node) else { return .absent }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: presenceLabelArguments(forNode: node))
    else { return PresenceReading(presence: .busy, confidence: .scanned) }

    let (succeeded, output) = await session.waitCollectingOutput()
    guard succeeded, let reported = parsePresenceLabel(output) else {
      return PresenceReading(presence: .busy, confidence: .scanned)
    }
    return PresenceReading(presence: reported, confidence: .reported)
  }

  /// Clears the presence label so the next reading falls back to busy. Codex only, and
  /// only because Codex is the backend with no way to say a turn has *started* — see
  /// `codexPresence`. Every other backend reports both edges and must not have its label
  /// second-guessed here.
  static func clearPresenceLabel(of node: LoopNode) async {
    guard ZmxLocator.isInstalled else { return }
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: [
          "set", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "presence=",
        ])
    else { return }
    _ = await session.waitUntilFinished()
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

  /// Whether the node has a live session at all. Internal rather than private because
  /// `CopilotSessionLog` needs the same liveness gate before it trusts a log tail: a
  /// killed session's log still ends at whatever it was doing.
  static func sessionExists(_ node: LoopNode) async -> Bool {
    guard
      let session = try? PTYProcessSession(
        executable: ZmxLocator.binaryURL.path,
        arguments: existenceCheckArguments(forNode: node))
    else { return false }
    return await session.waitUntilFinished()
  }

  /// Kills the session behind an id that isn't a graph node — a quick chat. Public
  /// because chats are app-owned: no daemon deletes their sessions for them, the way
  /// `GraphStore` does when a loop is deleted.
  public static func killSession(id: UUID) async {
    await kill(LoopNode(id: id, title: ""))
  }

  static func kill(_ node: LoopNode, projectPath: String? = nil) async {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      await killRemote(node, at: remote)
      return
    }
    SessionIDStore.remove(forNodeID: node.id)
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
  static func arguments(
    forNode node: LoopNode, projectPath: String? = nil,
    settings: GraphcodeSettings = GraphcodeSettingsStore.load()
  ) -> [String]? {
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
    //
    // A remote project's session gets the same briefing at a *remote* path: the ensure
    // dial delivers the file there (`remoteDeliveryScript`) and the forwarded socket
    // (`RemoteSocketForwarder`) makes the CLI it describes actually work from that host.
    let remote = projectPath.flatMap { RemoteProjectLocation.parse(projectPath: $0) }
    let briefingPath: String?
    if settings.briefsSessionsAboutTheGraph, let projectPath {
      briefingPath =
        remote == nil
        ? SessionBriefing.write(projectPath: projectPath)?.path
        : SessionBriefing.text(projectPath: projectPath)
          .map { _ in RemoteGraphAccess.briefingPath(forProjectPath: projectPath) }
    } else {
      briefingPath = nil
    }
    // The node's wake digest (`NodeMemory`): what previous passes learned, budgeted,
    // delivered by path for the same MAX_CANON reason as the briefing. `nil` on a first
    // launch (no memory yet). Pointed at from the *prompt* rather than the shared
    // per-project briefing file, because two nodes launching concurrently rewrite that
    // same AGENTS.md — per-node content there would race. The digest is always written
    // locally — the log lives on this machine either way — and a remote session is
    // pointed at the copy the ensure dial delivers to its own home directory. That
    // delivered copy is what makes a message staged to a sleeping remote loop actually
    // reach it at its next wake.
    let wakeFile =
      projectPath != nil
      ? NodeMemory.writeWakeDigest(projectPath: projectPath ?? "", nodeID: node.id) : nil
    let wakePath: String?
    if let projectPath, remote != nil {
      wakePath =
        wakeFile != nil
        ? RemoteGraphAccess.wakePath(forProjectPath: projectPath, nodeID: node.id) : nil
    } else {
      wakePath = wakeFile?.path
    }
    let promptWithMemory =
      wakePath.map { "Read your loop memory at \($0) before starting. Then: \(singleLine)" }
      ?? singleLine
    // Both the executable and the shape of its arguments come from the node's backend —
    // `claude` takes its prompt positionally and its briefing via `--append-system-prompt`,
    // `copilot` takes both together as `--interactive <prompt>`. Model tier is applied
    // here rather than baked into the prompt: it's the orchestrator's scheduling decision
    // (docs/05-orchestrator.md#responsibilities item 7).
    let tier = node.effectiveModelTier(autoSelecting: settings.autoSelectsModel)
    // The wake digest's directory joins the granted paths: Copilot and Codex verify
    // file access, and a pointer at a file the session is denied reads as the agent
    // ignoring its instructions — the same failure the briefing's `--add-dir` exists
    // to prevent. Claude Code ignores workspace paths, so this costs the others two
    // argv entries and Claude nothing.
    let wakeDirectory: String?
    if let projectPath, remote != nil {
      wakeDirectory =
        wakePath != nil
        ? RemoteGraphAccess.memoryDirectory(forProjectPath: projectPath, nodeID: node.id) : nil
    } else {
      wakeDirectory = wakeFile?.deletingLastPathComponent().path
    }
    let paths =
      Self.workspacePaths(forNode: node, projectPath: projectPath)
      + (wakeDirectory.map { [$0] } ?? [])
    // The hooks that make the session report what it is doing (`PresenceHooks`). For a
    // remote project the file can't come from here — it is written *on the remote host*
    // by the ensure script (`remoteEnsureInvocation`) and referenced as a `$HOME` path
    // only the remote shell can mint, via `scriptSuffix` below.
    let hooksFile = remote == nil ? PresenceHooks.write(forBackend: node.backend) : nil
    // Codex needs no file, only somewhere to report to. Nil for a remote session for the
    // same reason: it would name a binary at this machine's path on a host that has its
    // own.
    let reportingPath =
      remote == nil && ZmxLocator.isInstalled ? ZmxLocator.binaryURL.path : nil
    let remoteHooksSuffix =
      remote != nil && node.backend == .claudeCode
      ? " --settings \"\(PresenceHooks.remotePathExpression)\"" : ""
    let arguments = node.backend.launchArguments(
      prompt: promptWithMemory, tier: tier, briefingPath: briefingPath,
      settings: settings,
      workspacePaths: paths,
      hooksFile: hooksFile,
      sessionName: SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName,
      zmxPath: reportingPath)
    let command =
      [
        "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      ]
      + Self.loginShellInvocation(
        of: executable, arguments: arguments,
        environment: Self.environment(forBackend: node.backend, briefingPath: briefingPath),
        scriptSuffix: remoteHooksSuffix)

    // `zmx` types this command into the session's shell, and a tty in canonical mode
    // discards everything past `MAX_CANON` (1024 bytes on macOS). Overrunning it does not
    // fail loudly: the tail is dropped mid-argument and the shell waits forever at a
    // continuation prompt for a quote that was eaten. Dropping the briefing is the one
    // safe thing to give up — the prompt is the human's, and a loop that launches without
    // its briefing merely can't fan out, where a truncated one does nothing at all.
    guard Self.fitsInATypedCommandLine(command) else {
      // The hooks stay: they are two argv entries against the briefing's several hundred
      // bytes, and a loop that overran the line is exactly the one worth being able to
      // see the real state of.
      let unbriefed = node.backend.launchArguments(
        prompt: singleLine, tier: tier, settings: settings,
        workspacePaths: Self.workspacePaths(forNode: node, projectPath: projectPath),
        hooksFile: hooksFile,
        sessionName: SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName,
        zmxPath: reportingPath)
      return [
        "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      ]
        + Self.loginShellInvocation(
          of: executable, arguments: unbriefed, scriptSuffix: remoteHooksSuffix)
    }
    return command
  }

  /// `zmx run` argv that resumes an existing backend session instead of starting fresh.
  ///
  /// Used after a reboot: the zmx session is gone, but a persisted session ID lets the
  /// backend pick up where it left off. Falls back to `nil` when resume isn't possible
  /// (no persisted ID, unsupported backend, or the executable isn't found).
  static func resumeArguments(
    forNode node: LoopNode, sessionID: String, projectPath: String? = nil,
    settings: GraphcodeSettings = GraphcodeSettingsStore.load()
  ) -> [String]? {
    guard node.backend == .claudeCode || node.backend == .copilotCLI else { return nil }
    guard let executable = node.backend.executableName else { return nil }
    let remote = projectPath.flatMap { RemoteProjectLocation.parse(projectPath: $0) }
    guard remote == nil else { return nil }
    let tier = node.effectiveModelTier(autoSelecting: settings.autoSelectsModel)
    let hooksFile = PresenceHooks.write(forBackend: node.backend)
    let reportingPath = ZmxLocator.isInstalled ? ZmxLocator.binaryURL.path : nil
    let resumeArgs = node.backend.launchArguments(
      prompt: nil, tier: tier, settings: settings,
      workspacePaths: Self.workspacePaths(forNode: node, projectPath: projectPath),
      hooksFile: hooksFile,
      sessionName: SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName,
      zmxPath: reportingPath)
      + ["--resume", sessionID]
    return [
      "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
    ]
      + Self.loginShellInvocation(of: executable, arguments: resumeArgs)
  }

  /// The directories a loop's work legitimately spans: the project, and its worktree when
  /// it has one. A backend that verifies paths (Copilot) is told about both, because a
  /// loop bound to a worktree opens *there* and would otherwise be denied the repository
  /// it was branched from — see `CopilotPermissions.readableDirectories`.
  ///
  /// The global graph's reserved `graphcode://` path names no directory and is dropped.
  /// A remote project contributes its *remote* path — the directory as the session
  /// running on that host sees it, which is the one a path-verifying backend needs.
  static func workspacePaths(forNode node: LoopNode, projectPath: String?) -> [String] {
    var paths: [String] = []
    if let projectPath, !projectPath.hasPrefix("graphcode://") {
      if let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
        paths.append(remote.remotePath)
      } else {
        paths.append(projectPath)
      }
    }
    if let worktree = node.worktreeBinding?.worktreePath { paths.append(worktree) }
    return paths
  }

  /// Environment a session needs beyond what its shell provides. Nothing does, currently —
  /// Copilot's briefing rides on its argv (see `CLISessionBackendKind.launchArguments`)
  /// after the documented environment route turned out not to work. Kept because the
  /// plumbing is the awkward part and the next backend will want it.
  static func environment(forBackend backend: CLISessionBackendKind, briefingPath: String?)
    -> [String: String]
  {
    [:]
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
    // A global-graph loop — a watcher, or any trigger that belongs to no folder — opens
    // at home. Its reserved `graphcode://` path names no directory, and falling through
    // to nil would leave an unattended session in the daemon's own cwd, `/` under launchd.
    if projectPath.hasPrefix("graphcode://") { return NSHomeDirectory() }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return projectPath
  }

  // MARK: - Remote projects

  /// The local `ssh` argv that makes sure a remote node's session exists — `zmx get`
  /// checks and `zmx run` creates, **in one remote shell**, create-only either way.
  /// The zmx argv is exactly the local one — session name, detach, nested login shell,
  /// backend command — assembled into one quoted string, because ssh joins its
  /// arguments with spaces and hands them to the remote shell. `cd` first so the
  /// session opens in the repository, the remote twin of `workingDirectory`.
  ///
  /// One shell, not two ssh round-trips, and the difference was a bug, not tidiness:
  /// check-then-run left seconds of ssh latency between the two, and the app's own
  /// terminal attach creates the session too (`zmx attach` creates if needed). A
  /// `zmx run` that lands second doesn't fail — it *types the entire launch command
  /// into the now-live agent* — which surfaced as the whole zsh/copilot line sitting
  /// unsent in a remote Copilot's input bar. The `||` closes that window to what a
  /// single shell costs.
  static func remoteEnsureInvocation(
    forNode node: LoopNode, at location: RemoteProjectLocation,
    settings: GraphcodeSettings = GraphcodeSettingsStore.load()
  ) -> [String]? {
    guard
      let zmxArguments = arguments(
        forNode: node, projectPath: location.projectPath, settings: settings)
    else { return nil }
    let check = quotedCommand(["zmx"] + existenceCheckArguments(forNode: node))
    let run = remoteQuotedCommand(["zmx"] + zmxArguments)
    // Copilot only, and remote only: an unattended Copilot queues its `--interactive`
    // goal behind a per-session folder-trust dialog that nobody is present to answer,
    // so a fresh remote Copilot loop booted to an idle screen with its goal parked
    // forever (`--yolo` does not cover folder trust — measured). Pre-trusting the one
    // repository the loop was pointed at, on the host it runs on, is the same consent
    // the human gave by creating the loop there. The write is additive and idempotent
    // (the `trustedFolders` list in `~/.copilot/config.json`, schema read off a real
    // "remember this folder" answer), and any failure — no python3, malformed config —
    // falls back to today's behaviour: the dialog, answerable by opening the loop.
    let trustSeed =
      node.backend == .copilotCLI
      ? copilotTrustSeedScript(forRemotePath: location.remotePath) + "; " : ""
    let hooksWrite =
      node.backend == .claudeCode
      ? (PresenceHooks.remoteWriteFragment().map { $0 + "; " } ?? "") : ""
    let delivery =
      remoteDeliveryScript(forNode: node, at: location, settings: settings)
      .map { $0 + "; " } ?? ""
    let script =
      "cd \(RemoteProjectLocation.shellQuoted(location.remotePath)) && { "
      + trustSeed + hooksWrite + delivery
      + "\(check) >/dev/null 2>&1 || \(run); }"
    return location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(script))
  }

  /// The files a remote session needs on its own disk, as one installer fragment
  /// (`RemoteGraphAccess.installerScript`): always the CLI shim, plus the briefing when
  /// briefing is on and the node's wake digest when it has one. `node` is optional
  /// because the app's *attach* delivers too, before any node exists to have memory.
  /// Public for exactly that caller (`GhosttyTerminalView.remoteCommand`).
  public static func remoteDeliveryScript(
    forNode node: LoopNode?, at location: RemoteProjectLocation, settings: GraphcodeSettings
  ) -> String? {
    var files = [RemoteGraphAccess.cliInstallPath: RemoteGraphAccess.cliShimSource]
    if settings.briefsSessionsAboutTheGraph,
      let text = SessionBriefing.text(projectPath: location.projectPath)
    {
      files[RemoteGraphAccess.briefingPath(forProjectPath: location.projectPath)] = text
    }
    if let node {
      let wakeURL = NodeMemory.directory(
        forProjectPath: location.projectPath, nodeID: node.id
      ).appendingPathComponent(NodeMemory.wakeFileName)
      if let wake = try? String(contentsOf: wakeURL, encoding: .utf8) {
        files[RemoteGraphAccess.wakePath(forProjectPath: location.projectPath, nodeID: node.id)] =
          wake
      }
    }
    return RemoteGraphAccess.installerScript(files: files)
  }

  /// `quotedCommand`, except that arguments naming graphcode's own remote files —
  /// the `~/.graphcode/…` paths `RemoteGraphAccess` mints — keep their tilde outside
  /// the quotes as `~/'…'`, so the *remote* login shell expands it before `zmx`
  /// re-quotes the argv it received. Nothing local knows the remote home directory,
  /// and a fully-quoted `~` would reach the backend as a literal it can't open.
  /// Scoped to the `~/.graphcode/` prefix rather than any `~/` so a prompt that
  /// happens to start with a tilde is never rewritten.
  static func remoteQuotedCommand(_ argv: [String]) -> String {
    argv.map { argument in
      argument.hasPrefix("~/.graphcode/")
        ? "~/" + RemoteProjectLocation.shellQuoted(String(argument.dropFirst(2)))
        : RemoteProjectLocation.shellQuoted(argument)
    }.joined(separator: " ")
  }

  /// The additive, idempotent trust write described above. The repository path rides as
  /// an argument rather than being interpolated into the program, so a hostile path
  /// cannot become Python syntax; the whole command is neutered with `|| true` because
  /// a failed seed must never block the launch it precedes.
  static func copilotTrustSeedScript(forRemotePath remotePath: String) -> String {
    let program =
      "import json,os,sys; p=os.path.expanduser('~/.copilot/config.json'); "
      + "c=json.load(open(p)) if os.path.exists(p) else {}; "
      + "f=c.get('trustedFolders') or []; t=sys.argv[1]; "
      + "(t in f) or (f.append(t), c.update(trustedFolders=f), json.dump(c, open(p,'w')))"
    return quotedCommand(["python3", "-c", program, remotePath]) + " 2>/dev/null || true"
  }

  /// One argv as one shell-safe string — each argument quoted, so a prompt containing
  /// quotes, `$(…)`, or `;` stays one word through the remote shell exactly as it does
  /// through zmx's own quoting locally. Public because the app's remote *attach* is
  /// built from the same pieces (`GhosttyTerminalView.remoteCommand`).
  public static func quotedCommand(_ argv: [String]) -> String {
    argv.map(RemoteProjectLocation.shellQuoted).joined(separator: " ")
  }

  /// The remote twin of the local text-then-Enter delivery, in one ssh round-trip:
  /// type, give the composer its beat, then the Enter as its own keystroke — the same
  /// paste-heuristic dance the local path does, run on the host that owns the session.
  /// `zmx send` into a session that doesn't exist exits non-zero, so a dead remote
  /// loop reports failure and the caller stages the message, exactly like local.
  static func remoteSendInvocation(
    _ text: String, toNode node: LoopNode, at location: RemoteProjectLocation
  ) -> [String] {
    let send = quotedCommand(["zmx"] + sendArguments(text, toNode: node))
    let submit = quotedCommand(["zmx"] + submitArguments(forNode: node))
    let script = "\(send) && sleep 0.4 && \(submit)"
    return location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(script))
  }

  static func sendRemote(
    _ text: String, to node: LoopNode, at location: RemoteProjectLocation
  ) async -> Bool {
    guard !text.isEmpty else { return false }
    RemoteProjectLocation.prepareControlSocketDirectory()
    let invocation = remoteSendInvocation(text, toNode: node, at: location)
    guard
      let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst()))
    else { return false }
    return await session.waitUntilFinished()
  }

  /// What a remote session probe learned — and the three-way split is the point.
  /// `.unreachable` (the ssh dial failed) is a fact about the *link*; `.absent` (ssh
  /// answered, no such session) is a fact about the *session*. Collapsing them is how a
  /// network drop used to read as a stopped loop.
  enum RemoteSessionStatus: Equatable {
    case unreachable
    case absent
    case live(label: String?)
  }

  /// The one line of a probe's output this side parses. A marker rather than raw
  /// output because the remote login shell is interactive (`remoteLoginShellCommand`
  /// explains why) and a `~/.zshrc` is free to print whatever it likes first.
  static let remoteProbeMarker = "graphcode-status:"

  /// One ssh round-trip that answers existence and reads one label: exists-then-read as
  /// two dials would double the poll's connection count for no information.
  ///
  /// The script always exits 0 when it ran at all, so the process's exit status is left
  /// meaning exactly one thing: the transport. ssh failing (255) or the remote shell
  /// never reaching the script are `.unreachable`; what the session is up to travels on
  /// the marker line instead.
  static func remoteStatusInvocation(
    forNode node: LoopNode, label: String, at location: RemoteProjectLocation
  ) -> [String] {
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let check = quotedCommand(["zmx", "get", name])
    let read = quotedCommand(["zmx", "get", name, label])
    let script =
      "if \(check) >/dev/null 2>&1; then "
      + "echo \"\(remoteProbeMarker) live $(\(read) 2>/dev/null)\"; "
      + "else echo '\(remoteProbeMarker) absent'; fi"
    return location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(script))
  }

  static func remoteStatus(
    of node: LoopNode, label: String, at location: RemoteProjectLocation
  ) async -> RemoteSessionStatus {
    RemoteProjectLocation.prepareControlSocketDirectory()
    let invocation = remoteStatusInvocation(forNode: node, label: label, at: location)
    guard
      let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst()))
    else { return .unreachable }
    let (succeeded, output) = await session.waitCollectingOutput()
    return parseRemoteStatus(succeeded: succeeded, output: output)
  }

  /// The last marker line wins: everything before it is `~/.zshrc` chatter, and a probe
  /// that exited 0 without ever printing the marker didn't run, which is `.unreachable`
  /// too — not proof of anything about the session.
  static func parseRemoteStatus(succeeded: Bool, output: String) -> RemoteSessionStatus {
    guard succeeded else { return .unreachable }
    let lines = output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let marked = lines.last(where: { $0.hasPrefix(remoteProbeMarker) }) else {
      return .unreachable
    }
    let status = marked.dropFirst(remoteProbeMarker.count)
      .trimmingCharacters(in: .whitespaces)
    if status == "absent" { return .absent }
    guard status.hasPrefix("live") else { return .unreachable }
    let label = status.dropFirst("live".count).trimmingCharacters(in: .whitespaces)
    return .live(label: label.isEmpty ? nil : label)
  }

  /// The remote read behind `presence(of:projectPath:)` — both flavours share it, and
  /// differ only in what a live-but-silent session should be called (idle for a backend
  /// whose hooks report both edges, busy for Codex — see `codexPresence`).
  static func remotePresence(
    of node: LoopNode, at location: RemoteProjectLocation,
    liveWithoutLabel: PresenceReading
  ) async -> PresenceReading {
    presenceReading(
      from: await remoteStatus(of: node, label: "presence", at: location),
      liveWithoutLabel: liveWithoutLabel)
  }

  static func presenceReading(
    from status: RemoteSessionStatus, liveWithoutLabel: PresenceReading
  ) -> PresenceReading {
    switch status {
    case .unreachable: return .unknown
    case .absent: return .absent
    case .live(let label):
      guard let label, let reported = parsePresenceLabel(label) else { return liveWithoutLabel }
      return PresenceReading(presence: reported, confidence: .reported)
    }
  }

  /// Bounded retry with backoff for remote commands whose failure is overwhelmingly a
  /// transport blip — the multiplexed master redialing after a drop. Strictly for
  /// idempotent commands: ensure is create-only and kill is a no-op on a dead session,
  /// where a retried *send* could type the same message twice (its caller already has a
  /// staging fallback for the honest failure).
  static func runRemoteRetrying(_ invocation: [String], attempts: Int = 3) async -> Bool {
    RemoteProjectLocation.prepareControlSocketDirectory()
    for attempt in 1...attempts {
      if let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst())),
        await session.waitUntilFinished()
      {
        return true
      }
      if attempt < attempts { try? await Task.sleep(for: .seconds(1 << (attempt - 1))) }
    }
    return false
  }

  static func remoteKillInvocation(
    forNode node: LoopNode, at location: RemoteProjectLocation
  ) -> [String] {
    let script = quotedCommand(["zmx"] + killArguments(forNode: node))
    return location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(script))
  }

  static func killRemote(_ node: LoopNode, at location: RemoteProjectLocation) async {
    _ = await runRemoteRetrying(remoteKillInvocation(forNode: node, at: location))
  }

  private static func startRemote(_ node: LoopNode, at location: RemoteProjectLocation) async {
    // The forwarded socket is what makes the delivered CLI's dial land on this Mac's
    // daemon — without it the shim's commands have nowhere to go. Kept alive per host,
    // not per launch; see `RemoteSocketForwarder`.
    await RemoteSocketForwarder.shared.ensureForwarding(to: location)
    guard let ensure = remoteEnsureInvocation(forNode: node, at: location) else { return }
    // Create only, in one round-trip — see `remoteEnsureInvocation` for why the check
    // and the run must share a shell. A failure after the retries is the same posture
    // as the local path: no UI here, the node's state stays honest, opening the loop
    // retries.
    _ = await runRemoteRetrying(ensure)
  }

  static func start(_ node: LoopNode, projectPath: String? = nil) async {
    if let projectPath, let remote = RemoteProjectLocation.parse(projectPath: projectPath) {
      await startRemote(node, at: remote)
      return
    }
    guard ZmxLocator.isInstalled else { return }

    let zmxPath = ZmxLocator.binaryURL.path
    let checkArgs = existenceCheckArguments(forNode: node)
    let wd = workingDirectory(forNode: node, projectPath: projectPath)

    // Same atomic check-or-create as the remote path (`remoteEnsureInvocation`):
    // `zmx get` and `zmx run` in one shell, joined by `||`, so the app's own
    // `zmx attach` cannot slip in between and create the session first. Without
    // this, a `zmx run` that loses the race types the entire launch command into
    // the now-live agent's input — the `/bin/zsh -i` leak in the Copilot input bar.
    let sessionID: String? =
      SessionIDStore.load(forNodeID: node.id)
      ?? {
        guard node.backend == .copilotCLI else { return nil }
        let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
        return CopilotSessionLog.directory(forSessionNamed: name)?.lastPathComponent
      }()
    if let sessionID,
      let resumeArgs = resumeArguments(
        forNode: node, sessionID: sessionID, projectPath: projectPath)
    {
      await atomicCheckOrRun(checkArguments: checkArgs, runArguments: resumeArgs,
                             zmxPath: zmxPath, workingDirectory: wd)
      return
    }

    guard let runArgs = arguments(forNode: node, projectPath: projectPath) else { return }
    await atomicCheckOrRun(checkArguments: checkArgs, runArguments: runArgs,
                           zmxPath: zmxPath, workingDirectory: wd)
  }

  private static func atomicCheckOrRun(
    checkArguments: [String], runArguments: [String],
    zmxPath: String, workingDirectory: String?
  ) async {
    let check = quotedCommand([zmxPath] + checkArguments)
    let run = quotedCommand([zmxPath] + runArguments)
    let script = "\(check) >/dev/null 2>&1 || \(run)"
    guard let session = try? PTYProcessSession(
      executable: "/bin/zsh", arguments: ["-c", script],
      workingDirectory: workingDirectory)
    else { return }
    _ = await session.waitUntilFinished()
  }
}
