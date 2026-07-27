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
  static func arguments(forNode node: LoopNode) -> [String]? {
    guard let prompt = node.sessionPrompt, !prompt.isEmpty else { return nil }
    // CR/LF are the one thing quoting can't save us from: zmx terminates the command it
    // types with `\r`, and the PTY's line discipline would accept the line early at an
    // embedded one, truncating the prompt. Prompts come from a single-line text field, so
    // this only ever fires on a paste.
    let singleLine =
      prompt
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    // Model tier is applied here rather than baked into the prompt: it's the
    // orchestrator's scheduling decision (docs/05-orchestrator.md#responsibilities item
    // 7), and `--model` is how a backend takes one. `.standard` passes no flag at all,
    // which lets the backend's own default apply instead of us asserting what it is.
    let modelArguments = node.effectiveModelTier.modelAlias.map { ["--model", $0] } ?? []
    return [
      "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      "claude",
    ] + modelArguments + [singleLine]
  }

  static func start(_ node: LoopNode) async {
    guard ZmxLocator.isInstalled else { return }
    guard let arguments = arguments(forNode: node) else { return }

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
        workingDirectory: node.worktreeBinding?.worktreePath)
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
