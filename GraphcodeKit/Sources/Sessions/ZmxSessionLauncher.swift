import Foundation

/// Starts a time-based node's session, detached, so its loop runs whether or not the app
/// is open — the daemon-side half of `GraphStore.ensureTimeBasedSessions`.
///
/// This launches a session and then has nothing more to do with it. It does *not* drive
/// the schedule: the recurrence lives inside the session, expressed in the node's own
/// prompt via the backend's looping skill (see `LoopNode.triggerPrompt`). That split —
/// daemon owns liveness, session owns cadence — is what lets a human attach to a running
/// time-based loop and steer it, which a headless `claude -p` per tick never allowed.
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
  /// Fire-and-forget, matching `GraphStore.onEnsureSession`'s synchronous shape — the
  /// caller is an actor applying a graph command and shouldn't block on process spawning.
  public static let ensureSession: @Sendable (LoopNode) -> Void = { node in
    Task.detached { await start(node) }
  }

  /// `zmx get <name>` exits 0 when the session exists and 1 when it doesn't — the check
  /// that stops `ensureTimeBasedSessions()` from re-sending a prompt into a loop that's
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
    guard let prompt = node.triggerPrompt, !prompt.isEmpty else { return nil }
    // CR/LF are the one thing quoting can't save us from: zmx terminates the command it
    // types with `\r`, and the PTY's line discipline would accept the line early at an
    // embedded one, truncating the prompt. Prompts come from a single-line text field, so
    // this only ever fires on a paste.
    let singleLine =
      prompt
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    return [
      "run", SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName, "-d",
      "claude", singleLine,
    ]
  }

  private static func start(_ node: LoopNode) async {
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
