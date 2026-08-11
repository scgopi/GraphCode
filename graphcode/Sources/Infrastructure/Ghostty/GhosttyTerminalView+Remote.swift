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
  /// The loop's *reconnect* line is deliberately not the connect line again. For an
  /// agent surface it reattaches a session that still exists; one that is gone is
  /// either the loop finishing (or being killed) while disconnected — recreating it
  /// then would re-export the prompt and launch a second agent pass behind the human's
  /// back, so the pane closes with a notice — or the remote machine rebooting out from
  /// under it, which only a boot comparison can tell apart (`RemoteBootMarker`). A
  /// changed boot proves the session died with the machine, not that it finished, so
  /// the reconnect restores it the way relaunching the app always has: resume the
  /// backend session whose ID the `SessionStart` hook banked (the daemon's
  /// `remoteCreateScript` arrangement), or start fresh when there is nothing to
  /// resume. A plain shell has no such side effect, so its reconnect is the same
  /// create-or-attach as its connect.
  func remoteCommand(
    at location: RemoteProjectLocation, settings: GraphcodeSettings
  ) -> [String] {
    RemoteProjectLocation.prepareControlSocketDirectory()
    let quoted = RemoteProjectLocation.shellQuoted
    let delivery =
      ZmxSessionLauncher.remoteDeliveryScript(forNode: nil, at: location, settings: settings)
      .map { $0 + "; " } ?? ""
    let briefingPath = remoteBriefingPath(settings: settings)
    var script = delivery + "cd \(quoted(location.remotePath)) && "
    let reconnectScript: String
    let agentLaunch =
      launchesClaudeCode
      ? agentCommand(
        settings: settings, briefingPath: briefingPath,
        remoteSettingsPath: backend == .claudeCode ? PresenceHooks.remotePathExpression : nil)
      : nil
    if let agentLaunch {
      let markerWrite = RemoteBootMarker.writeFragment(forSessionName: sessionName)
      let hooksWrite = backend == .claudeCode ? PresenceHooks.remoteWriteFragment() : nil
      var promptExport = ""
      if let prompt = sessionEnvironment(briefingPath: briefingPath)[Self.promptVariable] {
        promptExport = "export \(Self.promptVariable)=\(quoted(prompt)) && "
      }
      script += markerWrite + " && "
      if let hooksWrite { script += hooksWrite + " && " }
      script += promptExport
      script += ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName] + agentLaunch)
      reconnectScript = agentReconnectScript(
        delivery: delivery, promptExport: promptExport, agentLaunch: agentLaunch,
        at: location, settings: settings)
    } else {
      script += ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName])
      reconnectScript = script
    }
    let connect = location.sshCommandLine(
      remoteCommand: location.remoteLoginShellCommand(script), interactive: true)
    let reconnect = location.sshCommandLine(
      remoteCommand: location.remoteLoginShellCommand(reconnectScript), interactive: true)
    return ["/bin/sh", "-c", SSHReconnectLoop.script(connect: connect, reconnect: reconnect)]
  }

  /// An agent surface's reconnect line, and the restore branch a proven reboot runs.
  ///
  /// `zmx get` exits 0 for a live session and 1 for a missing one — the same existence
  /// probe the daemon's ensure uses. Only that explicit 1 may even consider ending the
  /// pane: any other failure (`command not found` while the remote host is still
  /// booting, a broken login shell after wake) says nothing about the session, so it
  /// exits 255 — the one code the outer loop retries — instead of letting a transient
  /// error read as "the loop finished". A missing session then splits on the boot
  /// marker: same boot (or no marker to compare) closes the pane as before; a changed
  /// boot runs the restore. The get-then-attach race (session dying in between)
  /// recreates a blank shell, accepted because the window is milliseconds.
  ///
  /// The restore is the connect dial's own preparation (delivery, cd, marker, hooks),
  /// then resume-or-fresh. The resume ID is consumed before the attempt, exactly like
  /// `ZmxSessionLauncher.remoteCreateScript` and for the same reason: a dead ID retried
  /// forever would starve the fresh branch. The trailing `exit 255` catches a
  /// preparation step failing (the repository directory not mounted yet, a hooks write
  /// refused) — the host is mid-boot, so keep dialing rather than letting it read as
  /// "the loop finished".
  private func agentReconnectScript(
    delivery: String, promptExport: String, agentLaunch: [String],
    at location: RemoteProjectLocation, settings: GraphcodeSettings
  ) -> String {
    let quoted = RemoteProjectLocation.shellQuoted
    let markerWrite = RemoteBootMarker.writeFragment(forSessionName: sessionName)
    let hooksWrite = backend == .claudeCode ? PresenceHooks.remoteWriteFragment() : nil
    var restore = delivery + "if cd \(quoted(location.remotePath)); then \(markerWrite)"
    if let hooksWrite { restore += " && " + hooksWrite }
    restore += " && { "
    let nodeID = SurfaceRef.nodeID(fromZmxSessionName: sessionName)
    let resumeLaunch = resumeCommand(
      settings: settings,
      remoteSettingsPath: backend == .claudeCode ? PresenceHooks.remotePathExpression : nil)
    if let nodeID, let resumeLaunch {
      let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: nodeID)
      let idVariable = ZmxSessionLauncher.remoteResumeIDVariable
      restore +=
        "\(idVariable)=$(cat \(idFile) 2>/dev/null); "
        + "if [ -n \"$\(idVariable)\" ]; then rm -f \(idFile); export \(idVariable); "
        + "exec \(ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName] + resumeLaunch)); fi; "
    }
    restore +=
      promptExport
      + "exec \(ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName] + agentLaunch)); }; fi"
    let markerFile = RemoteBootMarker.markerExpression(forSessionName: sessionName)
    return
      "\(ZmxSessionLauncher.quotedCommand(["zmx", "get", sessionName])) >/dev/null 2>&1; "
      + "gc_rc=$?; if [ \"$gc_rc\" -eq 0 ]; then \(markerWrite); "
      + "exec \(ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName])); fi; "
      + "[ \"$gc_rc\" -ne 1 ] && exit 255; "
      + "\(RemoteBootMarker.captureFragment); gc_last=$(cat \(markerFile) 2>/dev/null); "
      + "if [ -n \"$gc_boot\" ] && [ -n \"$gc_last\" ] && [ \"$gc_boot\" != \"$gc_last\" ]; then "
      + #"printf '\033[1;33m── Remote machine rebooted; restoring the session. ──\033[0m\r\n'; "#
      + restore + "; exit 255; fi; "
      + #"printf '\033[2m── Remote session ended while disconnected. ──\033[0m\r\n'; exit 0"#
  }

  /// `agentCommand` for a session the remote machine's reboot killed: the same model and
  /// permission arguments, but resuming the backend session whose ID the `SessionStart`
  /// hook banked in `~/.graphcode/sessions` instead of starting a fresh one — what the
  /// daemon's ensure does after a reboot (`ZmxSessionLauncher.remoteCreateScript`),
  /// built here for the pane that is already dialing. `nil` when the backend cannot
  /// resume (Codex), which sends the restore branch to the fresh launch instead.
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
    guard backend == .claudeCode || backend == .copilotCLI,
      let executable = backend.executableName
    else { return nil }
    let tier = ModelTier.resolved(
      pinned: pinnedModelTier, for: loopType, autoSelecting: settings.autoSelectsModel)
    let model = backend.modelArguments(for: tier).joined(separator: " ")
    let permissions = backend.permissionArguments(settings).joined(separator: " ")
    var parts = ["exec", executable]
    if !model.isEmpty { parts.append(model) }
    if !permissions.isEmpty { parts.append(permissions) }
    if let remoteSettingsPath { parts.append("--settings \"\(remoteSettingsPath)\"") }
    parts.append("--resume \"$\(ZmxSessionLauncher.remoteResumeIDVariable)\"")
    return ["/bin/zsh", "-i", "-l", "-c", parts.joined(separator: " ")]
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
