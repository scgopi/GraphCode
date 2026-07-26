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
  let workingDirectory: String?
  let onProcessExited: (Bool) -> Void

  func makeNSView(context: Context) -> GhosttyTerminalNSView {
    let view = GhosttyTerminalNSView(
      command: command,
      workingDirectory: workingDirectory,
      environment: [:])
    view.onProcessExited = onProcessExited
    return view
  }

  func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}

  private var command: [String] {
    let claudeCommand = ["/bin/zsh", "-l", "-c", "exec claude"]
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
