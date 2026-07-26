import GraphcodeKit
import SwiftUI

/// The real, GhosttyKit-rendered terminal for a `LoopNode`'s session. Replaces the
/// Phase 1/2 `PlaceholderTerminalView` now that `GhosttyKit.xcframework` links and
/// `zmx` is buildable.
///
/// Ghostty owns the PTY and child process for `command` itself (see
/// `GhosttyTerminalNSView`) — when `zmx` is installed, `command` is a `zmx attach`
/// wrapper, so the session survives this view (and the whole app) closing, and
/// reopening the node reattaches to the same live session with its scrollback restored
/// by `zmx`'s own `ghostty-vt`-backed snapshot-on-attach, not by anything graphcode
/// does here.
struct GhosttyTerminalView: NSViewRepresentable {
  let node: LoopNode
  let onProcessExited: (Bool) -> Void

  func makeNSView(context: Context) -> GhosttyTerminalNSView {
    let view = GhosttyTerminalNSView(
      command: Self.command(for: node),
      workingDirectory: node.worktreeBinding?.worktreePath,
      environment: [:])
    view.onProcessExited = onProcessExited
    return view
  }

  func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {}

  private static func command(for node: LoopNode) -> [String] {
    let claudeCommand = ["/bin/zsh", "-l", "-c", "exec claude"]
    guard ZmxLocator.isInstalled else { return claudeCommand }
    let sessionName = "graphcode-\(node.id.uuidString)"
    return [ZmxLocator.binaryURL.path, "attach", sessionName] + claudeCommand
  }
}
