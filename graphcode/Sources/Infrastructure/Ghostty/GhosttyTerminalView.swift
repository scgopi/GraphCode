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
  /// This surface's `SurfaceRef.id` — the key its live `GhosttyTerminalNSView` is held
  /// under in `TerminalSurfaceStore`, so remounting the same pane borrows the terminal
  /// that is already running rather than building a second one.
  let surfaceID: UUID
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
  /// The project whose graph this loop belongs to — what the session's briefing tells it
  /// to create further loops *in*. Distinct from `workingDirectory`, which is the
  /// worktree when the node has one; a briefing built from the worktree path would have
  /// the agent extending a graph that doesn't exist. `nil` for plain-shell surfaces,
  /// which get no briefing.
  var projectPath: String?
  /// Whether this is *the* surface the user is typing into — its tab is the one on
  /// screen **and** it is that tab's focused pane. Every tab stays mounted and a split
  /// has two live terminals, so without this the keyboard can end up parked on a surface
  /// nobody can see, and both panes of a split draw a filled cursor as though each had it.
  var isActive: Bool = true
  /// Whether this surface's tab is the one on screen. Distinct from `isActive`, which is
  /// about the keyboard: both panes of a split are visible, only one is active. This is
  /// what libghostty is told, and it decides whether the surface renders at all — see
  /// `GhosttyTerminalNSView.syncOcclusion`.
  var isVisible: Bool = true
  /// The user clicked into this surface. See `GhosttyTerminalNSView.onFocusRequested`.
  var onFocusRequested: (() -> Void)?
  /// The user pressed a key on the "Process exited. Press any key to close." screen.
  /// See `GhosttyTerminalNSView.onExitAcknowledged`. `nil` for a plain-shell pane, whose
  /// exit closes the pane outright (`.paneClosed`) so the screen never lingers.
  var onExitAcknowledged: (() -> Void)?
  let onProcessExited: (Bool) -> Void

  /// Carries `initialPrompt` into the shell as a variable instead of interpolating it
  /// into the command string, so a prompt containing quotes, `$`, or backticks can't
  /// break out of (or inject into) the command Ghostty runs.
  static let promptVariable = "GRAPHCODE_TRIGGER_PROMPT"

  /// Returns a *host* rather than the surface itself, because the surface isn't this
  /// view's to own — `TerminalSurfaceStore` holds it, and this borrows it for as long as
  /// SwiftUI keeps the host mounted. See that type for why a terminal must outlive the
  /// view showing it.
  func makeNSView(context: Context) -> TerminalSurfaceHostView {
    let host = TerminalSurfaceHostView()
    let view = TerminalSurfaceStore.shared.surface(for: surfaceID) {
      // A remote surface needs the daemon's socket present on its host before the
      // delivered CLI can reach the graph — same forward the daemon's own launches
      // keep alive, started here for the sessions only an attach ever creates.
      if let location = remoteLocation {
        Task { await RemoteSocketForwarder.shared.ensureForwarding(to: location) }
      }
      // Written once per surface build, not held: like `ZmxSessionLauncher`, rewriting
      // on launch means the briefing never goes stale against an upgraded graphcode.
      let briefingPath = self.briefingFile()?.path
      return GhosttyTerminalNSView(
        command: command(briefingPath: briefingPath),
        workingDirectory: effectiveWorkingDirectory,
        environment: sessionEnvironment(
          briefingPath: briefingPath, hooksFile: presenceHooksFile()))
    }
    apply(to: view)
    host.adopt(view)
    return host
  }

  func updateNSView(_ host: TerminalSurfaceHostView, context: Context) {
    guard let view = host.surfaceView else { return }
    apply(to: view)
    // Switching tabs with ⌘-number moves what's visible but not what's focused — AppKit
    // only reassigns first responder on a click. Without this, hitting ⌘2 and typing
    // sent the keystrokes to tab 1's shell.
    view.focusIfKeyboardIsOnAHiddenSurface()
  }

  /// Everything about a surface that belongs to the *view* rather than to the terminal,
  /// pushed on both mount and update.
  ///
  /// The callbacks have to be re-assigned every pass, and now more than ever: a surface
  /// outlives the workspace that built it, so a closure captured when this pane last
  /// appeared would send its actions into a store scope for a loop nobody is looking at.
  private func apply(to view: GhosttyTerminalNSView) {
    view.isActive = isActive
    view.isVisible = isVisible
    view.remoteLocation = remoteLocation
    view.onFocusRequested = onFocusRequested
    view.onExitAcknowledged = onExitAcknowledged
    view.onProcessExited = onProcessExited
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
  /// `remoteSettingsPath` is the remote twin of `hooksFile`, as a `$HOME` shell
  /// expression rather than a URL: the file lives on the session's host, whose home
  /// directory only the remote shell knows, and the whole command is a `zsh -c` script
  /// precisely so the expansion happens there.
  func agentCommand(
    settings: GraphcodeSettings = GraphcodeSettingsStore.load(), briefingPath: String? = nil,
    hooksFile: URL? = nil, remoteSettingsPath: String? = nil
  ) -> [String]? {
    guard var parts = launchPrefix(settings: settings) else { return nil }
    let prompt = initialPrompt == nil ? "" : "\"$\(Self.promptVariable)\""
    // `/loop` lives behind Copilot's experimental flag, so a time-based node opened from
    // here rather than by the daemon would arm nothing at all without it — the same
    // parity this whole method exists for, since which path starts a session is a race.
    let opening = initialPrompt ?? ""
    if backend == .copilotCLI, SessionPrompt.mentionsRecurrence(opening) {
      parts.append("--experimental")
    }
    // Presence reporting, from the same place the daemon gets it (`PresenceHooks`). It
    // matters most here: a turn-based loop's session only ever starts from this view, so
    // without it the one loop type a human watches most closely would be the one that
    // could never say what it was doing. Quoted, unlike the model and permission flags,
    // because this one carries a path and the support directory can be relocated
    // (`GRAPHCODE_SUPPORT_DIR`) somewhere with a space in it.
    let presence =
      backend.presenceArguments(
        hooksFile: hooksFile, sessionName: sessionName,
        zmxPath: ZmxLocator.isInstalled ? ZmxLocator.binaryURL.path : nil
      )
      .map(PresenceHooks.singleQuoted)
      .joined(separator: " ")
    if !presence.isEmpty { parts.append(presence) }
    // Double-quoted, not `singleQuoted`: the `$HOME` inside must expand when the remote
    // shell evaluates this script.
    if let remoteSettingsPath { parts.append("--settings \"\(remoteSettingsPath)\"") }
    // The briefing, delivered the same per-backend way `BackendCommand.launchArguments`
    // delivers it for a daemon-started session — before this, only daemon-started loops
    // knew they could fan out, and a turn-based loop (which only ever starts here) asked
    // to create more loops improvised with its backend's own sub-agents instead (the
    // Copilot shape of issue #2). Claude takes the file itself as a flag; Copilot and
    // Codex are granted the directory and pointed at the file inside their opening
    // prompt — see `sessionEnvironment`, where the pointer rides in the env var and so
    // needs no shell quoting.
    // A remote session's briefing path is `~/`-relative and deliberately unquoted
    // here: this whole string is the remote zsh's `-c` script, and that shell's own
    // tilde expansion is the only thing that knows the remote home directory.
    if let briefingPath {
      if backend == .claudeCode {
        parts.append("--append-system-prompt-file \(briefingPath)")
      } else if backend.briefingNeedsDirectoryGrant {
        parts.append("--add-dir \((briefingPath as NSString).deletingLastPathComponent)")
      }
    }
    if !prompt.isEmpty {
      if let flag = backend.promptFlag { parts.append(flag) }
      parts.append(prompt)
    }
    return Self.interactiveLoginShell(parts)
  }

  /// The words every launch of this surface's agent starts from — executable, model,
  /// permissions — shared by the fresh launch above and the reboot resume
  /// (`resumeCommand`), so a flag every session needs cannot land in one and not the
  /// other.
  func launchPrefix(settings: GraphcodeSettings) -> [String]? {
    guard let executable = backend.executableName else { return nil }
    let tier = ModelTier.resolved(
      pinned: pinnedModelTier, for: loopType, autoSelecting: settings.autoSelectsModel)
    let model = backend.modelArguments(for: tier).joined(separator: " ")
    let permissions = backend.permissionArguments(settings).joined(separator: " ")
    var parts = ["exec", executable]
    if !model.isEmpty { parts.append(model) }
    if !permissions.isEmpty { parts.append(permissions) }
    return parts
  }

  /// The `-i -l` wrapper `agentCommand`'s doc explains — one place, so the resume and
  /// fresh launches cannot diverge on how the shell resolves the agent.
  static func interactiveLoginShell(_ parts: [String]) -> [String] {
    ["/bin/zsh", "-i", "-l", "-c", parts.joined(separator: " ")]
  }

  /// Where the graph briefing for this session landed, or `nil` when it shouldn't get
  /// one: a plain shell, a surface with no opening prompt to carry the pointer, a
  /// briefing the human switched off, nowhere to write — or a remote project, whose
  /// briefing is not a local file at all: `remoteBriefingPath` names where the attach
  /// dial delivers it on the session's own host.
  func briefingFile(settings: GraphcodeSettings = GraphcodeSettingsStore.load()) -> URL? {
    guard launchesClaudeCode, initialPrompt != nil, settings.briefsSessionsAboutTheGraph,
      remoteLocation == nil
    else { return nil }
    return SessionBriefing.write(projectPath: projectPath)
  }

  /// Where this session's presence hooks landed, or `nil` when it shouldn't get any: a
  /// plain shell has no agent to report, and a remote session runs on a machine this file
  /// was never written to.
  ///
  /// Unlike the briefing this has no setting to switch it off. A briefing changes what a
  /// loop *does* — it's prose in the agent's system prompt — so a human may reasonably not
  /// want it. Reporting only changes what the graph can see about work it is already
  /// doing, and an off switch there would only ever produce cards that lie.
  func presenceHooksFile() -> URL? {
    guard launchesClaudeCode, remoteLocation == nil else { return nil }
    return PresenceHooks.write(forBackend: backend)
  }

  /// Non-nil when this surface's project lives on another machine — the branch every
  /// remote decision hangs off. See `RemoteProjectLocation`.
  var remoteLocation: RemoteProjectLocation? {
    projectPath.flatMap { RemoteProjectLocation.parse(projectPath: $0) }
  }

  /// The local working directory for the surface's process. A remote project's path
  /// names no local folder — the `cd` happens inside the ssh command instead — and
  /// handing Ghostty a directory that doesn't exist would fail the spawn outright.
  var effectiveWorkingDirectory: String? {
    remoteLocation == nil ? workingDirectory : nil
  }

  /// What rides into the session through the environment: the opening prompt, carrying
  /// for Copilot and Codex the pointer at the briefing file — on whichever side keeps a
  /// leading `/loop` directive leading (`SessionPrompt`). In the env var rather
  /// than on the command line because the pointer is prose — inside `"$VAR"` it needs no
  /// quoting and cannot break the shell string the command is joined into. Claude's
  /// prompt stays untouched: its briefing arrives via `--append-system-prompt-file`.
  func sessionEnvironment(briefingPath: String?, hooksFile: URL? = nil) -> [String: String] {
    var environment = backend.presenceEnvironment(hooksFile: hooksFile)
    guard var prompt = initialPrompt else { return environment }
    if backend != .claudeCode, let briefingPath {
      prompt = SessionPrompt.composed(
        preamble: SessionBriefing.pointer(toBriefingAt: briefingPath), prompt: prompt)
    }
    environment[Self.promptVariable] = prompt
    return environment
  }

  private func command(briefingPath: String?) -> [String] {
    // A remote project's surfaces live on the remote host, local zmx or not.
    if let location = remoteLocation {
      return remoteCommand(at: location, settings: GraphcodeSettingsStore.load())
    }
    let shell = ["/bin/zsh", "-l"]
    guard
      let agentCommand = agentCommand(briefingPath: briefingPath, hooksFile: presenceHooksFile())
    else {
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
    guard launchesClaudeCode else { return command }
    if let resuming = localResumeOrFreshCommand(agentLaunch: agentCommand) {
      return resuming
    }
    command += agentCommand
    return command
  }

  /// Opening a loop whose session is gone used to start the agent **fresh**, prompt and
  /// all, because this was the one launch path that could not resume — `agentCommand`
  /// carries `sessionPrompt`, and only the daemon knew about `SessionIDStore`.
  ///
  /// That asymmetry cost a real conversation (2026-08-11). Something killed the zmx
  /// server — an app update replaces the `zmx` binary and reloads the daemon — and with
  /// no local liveness sweep nothing brought the sessions back. Opening the loops
  /// created fresh sessions here, whose `SessionStart` hooks rebanked their IDs over the
  /// ones holding days of work; the transcripts survived on disk with nothing pointing
  /// at them. Every reboot afterwards faithfully resumed the near-empty replacements.
  ///
  /// So this path resumes too, and the two launchers now make the same choice from the
  /// same banked ID. The check-then-launch is one `/bin/sh` script rather than an argv
  /// because the decision has to be made *here*, on the machine, at the moment the pane
  /// opens: whether a session exists, and whether the resume survived, are both facts
  /// only the shell holding the terminal can see.
  ///
  /// Deliberately *not* consuming the ID up front, which is what the remote path does:
  /// there, one restorer owns the loop, and here the daemon's ensure may be running the
  /// same resume concurrently. Two consumers racing on one `rm` is how the loser falls
  /// through to a fresh launch — the very failure this exists to end. It is dropped only
  /// once a resume has been *seen* to fail, which is also the check the daemon makes.
  ///
  /// `nil` for a backend that cannot resume, or a node with nothing banked: both take
  /// the ordinary fresh launch.
  func localResumeOrFreshCommand(agentLaunch: [String]) -> [String]? {
    let settings = GraphcodeSettingsStore.load()
    guard let nodeID = SurfaceRef.nodeID(fromZmxSessionName: sessionName),
      SessionIDStore.load(forNodeID: nodeID) != nil,
      let resumeLaunch = resumeCommand(
        settings: settings, hooksFile: presenceHooksFile(), remoteSettingsPath: nil)
    else { return nil }
    let zmx = ZmxLocator.binaryURL.path
    let quoted = RemoteProjectLocation.shellQuoted
    let idFile = quoted(SessionIDStore.file(forNodeID: nodeID).path)
    let attach = ZmxSessionLauncher.quotedCommand([zmx, "attach", sessionName])
    let resume = ZmxSessionLauncher.quotedCommand(
      [zmx, "attach", sessionName] + resumeLaunch)
    let fresh = ZmxSessionLauncher.quotedCommand([zmx, "attach", sessionName] + agentLaunch)
    let exists = ZmxSessionLauncher.quotedCommand([zmx, "get", sessionName])
    // A live session is joined as it always was — the resume argv would be ignored by
    // `zmx attach` anyway, and building it costs a settings read nobody needs.
    let idVariable = ZmxSessionLauncher.remoteResumeIDVariable
    let settle = ZmxSessionLauncher.resumeSettleSeconds
    let log = { (event: String) in
      DialLog.fragment(session: self.sessionName, dial: "open", event: event) + "; "
    }
    let joined = "\(exists) >/dev/null 2>&1 && { \(log("attach-live"))exec \(attach); }; "
    let read = "\(idVariable)=$(cat \(idFile) 2>/dev/null); "
    let attempt =
      "if [ -n \"$\(idVariable)\" ]; then export \(idVariable); \(log("resume"))"
      + "gc_t0=$(date +%s); "
      + resume + "; gc_rc=$?; "
    let verdict =
      "[ $(($(date +%s) - gc_t0)) -ge \(settle) ] && exit \"$gc_rc\"; rm -f \(idFile); "
      + log("resume-dead")
      + #"printf '\033[1;33m── Resume did not take; starting fresh. ──\033[0m\r\n'; fi; "#
    let script = joined + read + attempt + verdict + log("fresh") + "exec \(fresh)"
    return ["/bin/sh", "-c", script]
  }
}
