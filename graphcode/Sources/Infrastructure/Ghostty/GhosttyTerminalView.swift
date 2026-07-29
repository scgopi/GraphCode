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
  /// The tier the human pinned for this loop, and the loop's type — the two inputs the
  /// routing policy takes. Deliberately *unresolved*: whether an unpinned loop gets a
  /// model at all depends on a setting, and the settings read already happens inside
  /// `agentCommand`. Resolving it out in `LoopWorkspaceView` instead would mean loading
  /// the settings file on every SwiftUI body pass.
  var pinnedModelTier: ModelTier?
  var loopType: LoopType = .turnBased
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
  /// Whether this is *the* surface the user is typing into — its tab is the one on
  /// screen **and** it is that tab's focused pane. Every tab stays mounted and a split
  /// has two live terminals, so without this the keyboard can end up parked on a surface
  /// nobody can see, and both panes of a split draw a filled cursor as though each had it.
  var isActive: Bool = true
  /// The user clicked into this surface. See `GhosttyTerminalNSView.onFocusRequested`.
  var onFocusRequested: (() -> Void)?
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
    view.onFocusRequested = onFocusRequested
    view.isActive = isActive
    return view
  }

  func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
    nsView.isActive = isActive
    // Re-assigned every pass: the closure captures the store action for *this* pane in
    // *this* tab, and a stale one from an earlier layout would focus the wrong pane.
    nsView.onFocusRequested = onFocusRequested
    // Switching tabs with ⌘-number moves what's visible but not what's focused — AppKit
    // only reassigns first responder on a click. Without this, hitting ⌘2 and typing
    // sent the keystrokes to tab 1's shell.
    nsView.focusIfKeyboardIsOnAHiddenSurface()
  }

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
  ///
  /// How much the session may do without asking comes from the same setting the daemon
  /// reads (`GraphcodeSettings.claudePermissionMode` and its per-backend siblings), for
  /// the reason the two paths exist at all: which one starts a node's session is a race —
  /// the daemon if it got there first, this view if the node was opened before it did, or
  /// with `zmx` not installed. Omitting the flag here meant that race decided whether a
  /// loop ran on the setting a human chose or on the CLI's interactive default, where it
  /// sits at the first prompt while the graph reports it as `running`.
  ///
  /// Loaded per launch rather than held, matching `ZmxSessionLauncher`: changing the
  /// setting then applies to the next session opened, with nothing to restart.
  /// `settings` is a parameter rather than a read inside the body so a test can state what
  /// a human chose and check what the shell is told — the omission this fixes was
  /// invisible precisely because there was nothing to assert against.
  func agentCommand(settings: GraphcodeSettings = GraphcodeSettingsStore.load()) -> [String]? {
    guard let executable = backend.executableName else { return nil }
    let tier = ModelTier.resolved(
      pinned: pinnedModelTier, for: loopType, autoSelecting: settings.autoSelectsModel)
    let model = backend.modelArguments(for: tier).joined(separator: " ")
    let permissions = backend.permissionArguments(settings).joined(separator: " ")
    let prompt = initialPrompt == nil ? "" : "\"$\(Self.promptVariable)\""

    var parts = ["exec", executable]
    if !model.isEmpty { parts.append(model) }
    if !permissions.isEmpty { parts.append(permissions) }
    if !prompt.isEmpty {
      if backend == .copilotCLI { parts.append("--interactive") }
      parts.append(prompt)
    }
    return ["/bin/zsh", "-i", "-l", "-c", parts.joined(separator: " ")]
  }

  private var command: [String] {
    let shell = ["/bin/zsh", "-l"]
    guard let agentCommand = agentCommand() else {
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
