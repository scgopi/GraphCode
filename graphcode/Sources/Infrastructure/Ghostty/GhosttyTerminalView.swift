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

  private var command: [String] {
    let claudeCommand =
      initialPrompt == nil
      ? ["/bin/zsh", "-l", "-c", "exec claude"]
      : ["/bin/zsh", "-l", "-c", "exec claude \"$\(Self.promptVariable)\""]
    guard ZmxLocator.isInstalled else {
      return launchesClaudeCode ? claudeCommand : ["/bin/zsh", "-l"]
    }
    // `zmx attach <name>` with no trailing command spawns a login shell directly — no
    // wrapper needed for a plain-shell surface.
    var command = [ZmxLocator.binaryURL.path, "attach", sessionName]
    if launchesClaudeCode { command += claudeCommand }
    return command
  }
}
