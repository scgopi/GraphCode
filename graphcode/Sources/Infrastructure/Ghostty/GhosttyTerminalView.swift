import GraphcodeKit
import SwiftUI

/// The real, GhosttyKit-rendered terminal for one surface in a loop's terminal
/// workspace (see `LoopWorkspaceFeature`) — replaces the Phase 1/2
/// `PlaceholderTerminalView` now that `GhosttyKit.xcframework` links and `zmx` is
/// buildable.
///
/// Ghostty owns the PTY and child process for `command` itself (see
/// `GhosttyTerminalNSView`) — when `zmx` is installed, `command` is a `zmx attach`
/// wrapper, so the session survives this view (and the whole app) closing, and
/// reopening it reattaches to the same live session with its scrollback restored by
/// `zmx`'s own `ghostty-vt`-backed snapshot-on-attach, not by anything graphcode does
/// here. Parameterized by session name/launch behavior rather than a whole `LoopNode`
/// since one loop can now have several surfaces (tabs/splits), only one of which
/// launches Claude Code — see `SurfaceRef.launchesClaudeCode`.
struct GhosttyTerminalView: NSViewRepresentable {
  let sessionName: String
  let launchesClaudeCode: Bool
  /// Which agent this surface starts, when it starts one. Previously the command was
  /// hardcoded to `claude`, so a loop configured for Copilot opened a Claude Code
  /// session — the picker and the running process disagreeing, with nothing on screen
  /// to say so.
  var backend: CLISessionBackendKind = .claudeCode
  /// The tier that agent runs at, so an attached session matches what `graphcoded` would
  /// have launched detached.
  var modelTier: ModelTier = .standard
  /// The prompt this surface's Claude Code session should start with — a time-based
  /// node's `/loop …` directive (see `LoopNode.triggerPrompt`). `nil` for a turn-based
  /// loop's session, which starts bare, and for every plain-shell surface.
  ///
  /// Only reached when this view is the one *creating* the session. Once `graphcoded`
  /// has started a time-based node's session, `zmx attach` ignores its command argument
  /// entirely and just joins the live one — so this is the fallback path for a node
  /// opened before the daemon got to it, or with `zmx` not installed.
  var initialPrompt: String?
  let workingDirectory: String?
  let onProcessExited: (Bool) -> Void

  /// Carries `initialPrompt` into the shell as a variable instead of interpolating it
  /// into the command string, so a prompt containing quotes, `$`, or backticks can't
  /// break out of (or inject into) the command Ghostty runs.
  private static let promptVariable = "GRAPHCODE_TRIGGER_PROMPT"

  func makeNSView(context: Context) -> GhosttyTerminalNSView {
    let view = GhosttyTerminalNSView(
      command: command,
      workingDirectory: workingDirectory,
      environment: initialPrompt.map { [Self.promptVariable: $0] } ?? [:])
    view.onProcessExited = onProcessExited
    return view
  }

  func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}

  /// The agent invocation, built from the node's own backend rather than assumed.
  ///
  /// The prompt still rides in through the environment rather than being interpolated
  /// into the command string, so one containing quotes, `$`, or backticks can't break out
  /// of it — but *where* it goes is the backend's business: `claude` takes it
  /// positionally, `copilot` as the value of `--interactive`.
  ///
  /// `-i` as well as `-l`, for the same reason the daemon's launcher needs it (see
  /// `ZmxSessionLauncher.loginShellInvocation`): a developer's `PATH` usually comes from
  /// `~/.zshrc`, which zsh reads only when interactive. The app inherits `launchd`'s
  /// minimal `PATH` when opened from Finder, so without `-i` this finds the agent only
  /// when the app happened to be launched from an already-configured shell.
  private var agentCommand: [String]? {
    guard let executable = backend.executableName else { return nil }
    let model = backend.modelArguments(for: modelTier).joined(separator: " ")
    let prompt = initialPrompt == nil ? "" : "\"$\(Self.promptVariable)\""

    var parts = ["exec", executable]
    if !model.isEmpty { parts.append(model) }
    if !prompt.isEmpty {
      if backend == .copilotCLI { parts.append("--interactive") }
      parts.append(prompt)
    }
    return ["/bin/zsh", "-i", "-l", "-c", parts.joined(separator: " ")]
  }

  private var command: [String] {
    let shell = ["/bin/zsh", "-l"]
    guard let agentCommand else {
      // A backend graphcode can't launch gets a plain shell rather than the wrong agent.
      // `canHost` already refuses to create such a node, so this is unreachable in
      // practice and deliberately inert if it ever isn't.
      return ZmxLocator.isInstalled
        ? [ZmxLocator.binaryURL.path, "attach", sessionName] : shell
    }
    guard ZmxLocator.isInstalled else {
      return launchesClaudeCode ? agentCommand : shell
    }
    // `zmx attach <name>` with no trailing command spawns a login shell directly — no
    // wrapper needed for a plain-shell surface.
    var command = [ZmxLocator.binaryURL.path, "attach", sessionName]
    if launchesClaudeCode { command += agentCommand }
    return command
  }
}
