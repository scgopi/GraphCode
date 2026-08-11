import GraphcodeKit

/// The remote half of `GhosttyTerminalView`: the ssh dial a surface runs when its
/// project lives on another machine, and the reconnect behaviour that keeps it alive
/// across network drops and host reboots.
extension GhosttyTerminalView {
  /// The argv for a surface whose project is remote: a local `/bin/sh` reconnect loop
  /// (`SSHReconnectLoop`) around the `ssh -t … zmx attach` dial — both kinds: an agent
  /// surface attaches (or creates) the loop's session on the remote host, and a plain
  /// shell opens a remote shell in the repository, which is the shell a remote project's
  /// extra tabs should give you.
  ///
  /// The opening prompt cannot ride in through the local environment the way it does
  /// locally: sshd does not accept arbitrary client env. It is assigned inside the
  /// remote command instead, single-quote-escaped, where the session's shell — spawned
  /// by remote zmx under this very process — inherits it and expands the same
  /// `"$GRAPHCODE_TRIGGER_PROMPT"` reference the local path uses.
  ///
  /// A plain shell's reconnect is the same create-or-attach as its connect — it has no
  /// side effect to guard. An agent surface's reconnect is `remoteAgentScripts`'s
  /// second script; see there for the session-gone split it makes.
  func remoteCommand(
    at location: RemoteProjectLocation, settings: GraphcodeSettings
  ) -> [String] {
    RemoteProjectLocation.prepareControlSocketDirectory()
    let quoted = RemoteProjectLocation.shellQuoted
    let delivery =
      ZmxSessionLauncher.remoteDeliveryScript(forNode: nil, at: location, settings: settings)
      .map { $0 + "; " } ?? ""
    let agentScripts =
      launchesClaudeCode
      ? remoteAgentScripts(delivery: delivery, at: location, settings: settings) : nil
    // A plain shell — and a backend graphcode can't launch — is create-or-attach both
    // times: there is no agent pass to accidentally run twice.
    let shell =
      delivery + "cd \(quoted(location.remotePath)) && "
      + ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName])
    let script = agentScripts?.connect ?? shell
    let reconnectScript = agentScripts?.reconnect ?? shell
    let connect = location.sshCommandLine(
      remoteCommand: location.remoteLoginShellCommand(script), interactive: true)
    let reconnect = location.sshCommandLine(
      remoteCommand: location.remoteLoginShellCommand(reconnectScript), interactive: true)
    return ["/bin/sh", "-c", SSHReconnectLoop.script(connect: connect, reconnect: reconnect)]
  }

  /// An agent surface's connect and reconnect scripts, built from fragments computed
  /// once so the two dials cannot drift apart on preparation.
  ///
  /// The reconnect is deliberately not the connect again. `zmx get` exits 0 for a live
  /// session and 1 for a missing one — the same existence probe the daemon's ensure
  /// uses. A live session is reattached (refreshing the boot marker, so a survived
  /// reboot cannot poison a later verdict). Any exit but the explicit 1 says nothing
  /// about the session — `command not found` while the host boots, a broken login shell
  /// after wake — so it exits 255, the one code the outer loop retries. A missing
  /// session splits on the boot marker (`RemoteBootMarker`): the same boot (or nothing
  /// to compare) means the loop finished while disconnected — recreating it would
  /// launch a second agent pass behind the human's back, so the pane closes with a
  /// notice, exactly as it always has. A changed boot proves the session died with the
  /// machine instead, and what happens next depends on who restores this loop:
  ///
  /// - An **unattended** loop (time- or goal-based) is `graphcoded`'s to restore: its
  ///   liveness sweep already recreates the session with the banked resume ID, under
  ///   `RemoteEnsureGate`. The pane joining in was measured to *race* that restore —
  ///   both consumed the same ID file, and the loser's `cat` came back empty, so the
  ///   loop restarted fresh instead of resuming. The pane therefore only announces the
  ///   reboot and keeps dialing; the moment the sweep has the session back, the
  ///   reattach branch picks it up. A loop the daemon will never restore — resolved,
  ///   killed — leaves the pane at that banner until the human closes it: visibly
  ///   waiting, never silently relaunching.
  /// - A **turn-based** loop has no other restorer — the daemon deliberately never
  ///   starts one — so the pane restores it itself: `restoreScript`.
  ///
  /// The get-then-attach race (session dying in between) recreates a blank shell,
  /// accepted because the window is milliseconds.
  private func remoteAgentScripts(
    delivery: String, at location: RemoteProjectLocation, settings: GraphcodeSettings
  ) -> (connect: String, reconnect: String)? {
    let quoted = RemoteProjectLocation.shellQuoted
    let briefingPath = remoteBriefingPath(settings: settings)
    guard
      let agentLaunch = agentCommand(
        settings: settings, briefingPath: briefingPath,
        remoteSettingsPath: backend == .claudeCode ? PresenceHooks.remotePathExpression : nil)
    else { return nil }
    let markerWrite = RemoteBootMarker.writeFragment(forSessionName: sessionName)
    let hooksWrite =
      (backend == .claudeCode ? PresenceHooks.remoteWriteFragment() : nil)
      .map { $0 + " && " } ?? ""
    var promptExport = ""
    if let prompt = sessionEnvironment(briefingPath: briefingPath)[Self.promptVariable] {
      promptExport = "export \(Self.promptVariable)=\(quoted(prompt)) && "
    }
    let attachFresh = ZmxSessionLauncher.quotedCommand(
      ["zmx", "attach", sessionName] + agentLaunch)
    let connect =
      delivery + "cd \(quoted(location.remotePath)) && "
      + markerWrite + " && " + hooksWrite + promptExport + attachFresh
    let rebootBranch: String
    if loopType == .turnBased {
      let preparation = delivery + "if cd \(quoted(location.remotePath)); then " + hooksWrite
      rebootBranch =
        #"printf '\033[1;33m── Remote machine rebooted; restoring the session. ──\033[0m\r\n'; "#
        + restoreScript(
          preparation: preparation, promptExport: promptExport, attachFresh: attachFresh,
          settings: settings) + "; exit 255"
    } else {
      rebootBranch =
        #"printf '\033[1;33m── Remote machine rebooted; waiting for the loop session "#
        + #"to be restored. ──\033[0m\r\n'; exit 255"#
    }
    let markerFile = RemoteBootMarker.markerExpression(forSessionName: sessionName)
    let reconnect =
      "\(ZmxSessionLauncher.quotedCommand(["zmx", "get", sessionName])) >/dev/null 2>&1; "
      + "gc_rc=$?; if [ \"$gc_rc\" -eq 0 ]; then \(markerWrite); "
      + "exec \(ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName])); fi; "
      + "[ \"$gc_rc\" -ne 1 ] && exit 255; "
      + "\(RemoteBootMarker.captureFragment); gc_last=$(cat \(markerFile) 2>/dev/null); "
      + "if [ -n \"$gc_boot\" ] && [ -n \"$gc_last\" ] && [ \"$gc_boot\" != \"$gc_last\" ]; then "
      + rebootBranch + "; fi; "
      + #"printf '\033[2m── Remote session ended while disconnected. ──\033[0m\r\n'; exit 0"#
    return (connect, reconnect)
  }

  /// The turn-based restore a proven reboot runs: the connect dial's own preparation
  /// (already in `preparation` — delivery, cd, hooks), then resume-or-fresh.
  ///
  /// The resume ID is consumed before the attempt
  /// (`ZmxSessionLauncher.resumeOrFreshScript` — the daemon's own fragment, shared so
  /// the invariant cannot drift). A resume that dies within seconds is a dead ID —
  /// `claude --resume` against a pruned transcript exits immediately — and only this
  /// attached script can see that, so it measures: an attach that returned in under
  /// five seconds falls through to the fresh launch instead of closing the pane with a
  /// pass-through exit code. One that lived longer was a real session, and its exit is
  /// the session ending, passed through as ever.
  ///
  /// The boot marker is deliberately *not* refreshed here: it updates only when an
  /// attach finds a live session. A drop mid-restore therefore redials into this same
  /// branch — with the marker already rewritten it would have read as "ended while
  /// disconnected" and closed the pane on a reboot that was real.
  ///
  /// The trailing `exit 255` in the caller catches a preparation step failing (the
  /// repository directory not mounted yet, a hooks write refused) — the host is
  /// mid-boot, so keep dialing rather than letting it read as "the loop finished".
  private func restoreScript(
    preparation: String, promptExport: String, attachFresh: String, settings: GraphcodeSettings
  ) -> String {
    var script = preparation + "{ "
    let nodeID = SurfaceRef.nodeID(fromZmxSessionName: sessionName)
    let resumeLaunch = resumeCommand(
      settings: settings,
      remoteSettingsPath: backend == .claudeCode ? PresenceHooks.remotePathExpression : nil)
    if let nodeID, let resumeLaunch {
      let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: nodeID)
      let attempt =
        "export \(ZmxSessionLauncher.remoteResumeIDVariable); gc_t0=$(date +%s); "
        + ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName] + resumeLaunch)
        + "; gc_rc=$?; [ $(($(date +%s) - gc_t0)) -ge 5 ] && exit \"$gc_rc\"; "
        + #"printf '\033[1;33m── Resume did not take; starting the session fresh. ──\033[0m\r\n'"#
      script += ZmxSessionLauncher.resumeOrFreshScript(idFile: idFile, resume: attempt) + "; "
    }
    script += promptExport + "exec \(attachFresh); }; fi"
    return script
  }

  /// `agentCommand` for a session the remote machine's reboot killed: the same launch
  /// prefix (`launchPrefix` — executable, model, permissions), resuming the backend
  /// session whose ID the `SessionStart` hook banked in `~/.graphcode/sessions` instead
  /// of starting a fresh one. `nil` when the backend cannot resume
  /// (`CLISessionBackendKind.supportsResume`), which sends the restore to the fresh
  /// launch instead.
  ///
  /// The ID reaches the session as `"$GRAPHCODE_RESUME_ID"`, unexpanded inside this
  /// single-quoted script the same way the opening prompt does: the restore shell reads
  /// the file, exports the variable, and the session's shell — spawned by remote zmx
  /// under that very process — inherits it. No opening prompt and no briefing: a resumed
  /// conversation already had both. No `--name` for Copilot either — it is mutually
  /// exclusive with `--resume` (see `ZmxSessionLauncher.resumeArguments`).
  func resumeCommand(
    settings: GraphcodeSettings, remoteSettingsPath: String?
  ) -> [String]? {
    guard backend.supportsResume, var parts = launchPrefix(settings: settings) else {
      return nil
    }
    if let remoteSettingsPath { parts.append("--settings \"\(remoteSettingsPath)\"") }
    parts.append("--resume \"$\(ZmxSessionLauncher.remoteResumeIDVariable)\"")
    return Self.interactiveLoginShell(parts)
  }

  /// The remote twin of `briefingFile`: the `~/`-relative path the briefing is
  /// delivered to on the remote host, under the same guards.
  func remoteBriefingPath(settings: GraphcodeSettings = GraphcodeSettingsStore.load()) -> String? {
    guard launchesClaudeCode, initialPrompt != nil, settings.briefsSessionsAboutTheGraph,
      remoteLocation != nil, let projectPath
    else { return nil }
    return RemoteGraphAccess.briefingPath(forProjectPath: projectPath)
  }
}
