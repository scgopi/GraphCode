import Foundation
import GraphcodeKit

/// The remote half of `GhosttyTerminalView`: the ssh dial a surface runs when its
/// project lives on another machine, and the reconnect behaviour that keeps it alive
/// across network drops and host reboots.
extension GhosttyTerminalView {
  /// The argv for a surface whose project is remote: a local `/bin/sh` reconnect loop
  /// (`SSHReconnectLoop`) around the `ssh -t … zmx attach` dial — both kinds: an agent
  /// surface joins (or, when it owns the launch, creates) the loop's session on the
  /// remote host — see `remoteAgentScripts` for who owns what — and a plain shell opens
  /// a remote shell in the repository, which is the shell a remote project's extra tabs
  /// should give you.
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
  /// Both dials open the same way (`reattachOrRetry`): `zmx get` exits 0 for a live
  /// session and 1 for a missing one — the same existence probe the daemon's ensure
  /// uses. A live session is reattached (refreshing the boot marker, so a survived
  /// reboot cannot poison a later verdict). Any exit but the explicit 1 says nothing
  /// about the session — `command not found` while the host boots, a broken login shell
  /// after wake — so it exits 255, the one code the outer loop retries.
  ///
  /// The connect used to be a bare create-or-attach carrying the goal prompt, which
  /// held only while one surface process survived a whole outage: surfaces are
  /// LRU-retained (`SurfaceRetentionPolicy`) and every rebuild — a screen switch, an
  /// app relaunch, reopening the loop — dialed connect again. Rebuilt while the remote
  /// host's reboot had the session down, that dial re-ran the goal from scratch and
  /// its `SessionStart` hook rebanked the fresh ID over the one holding the work,
  /// racing the very restore `graphcoded` was making. So a missing session now takes
  /// the same ownership split on *both* dials:
  ///
  /// - An **unattended** loop (time- or goal-based) is `graphcoded`'s to (re)start: its
  ///   ensure runs at node creation, at graph load, and every liveness sweep, with the
  ///   banked resume ID under `RemoteEnsureGate`. The pane only announces and keeps
  ///   dialing; the moment the daemon has the session, the reattach branch picks it up.
  ///   A loop the daemon will never restore — resolved, killed — leaves the pane at
  ///   that banner until the human closes it: visibly waiting, never silently
  ///   relaunching.
  /// - A **turn-based** loop has no other restorer — the daemon deliberately never
  ///   starts one — so the pane restores it itself: `restoreScript`, whose fresh
  ///   fall-through is also the legitimate first launch of a loop nothing has banked
  ///   an ID for. Only the connect writes the boot marker on that create
  ///   (`freshPrefix`); the reconnect's restore runs behind a *proven* reboot and
  ///   deliberately leaves the marker alone — see `restoreScript`.
  ///
  /// The reconnect additionally splits a missing session on the boot marker
  /// (`RemoteBootMarker`): the same boot (or nothing to compare) means the loop
  /// finished while disconnected — recreating it would launch a second agent pass
  /// behind the human's back, so the pane closes with a notice, exactly as it always
  /// has. A changed boot proves the session died with the machine and enters the split
  /// above. The connect has no such verdict to make: it is the first dial, so a missing
  /// session is either not started yet or died while no pane was watching — both roads
  /// lead to the same owner.
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
    // Every branch below records itself in the remote host's dial log
    // (`DialLog.fragment`) before it acts — the banners announce the same decisions,
    // but they die with the scrollback.
    let log = { (dial: String, event: String) in
      DialLog.fragment(session: self.sessionName, dial: dial, event: event) + "; "
    }
    let reattachOrRetry = { (dial: String) in
      "\(ZmxSessionLauncher.quotedCommand(["zmx", "get", sessionName])) >/dev/null 2>&1; "
        + "gc_rc=$?; if [ \"$gc_rc\" -eq 0 ]; then \(log(dial, "attach-live"))\(markerWrite); "
        + "exec \(ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName])); fi; "
        + "[ \"$gc_rc\" -ne 1 ] && exit 255; "
    }
    let restorePreparation = "if cd \(quoted(location.remotePath)); then " + hooksWrite
    let connectMissing: String
    if loopType == .turnBased {
      connectMissing =
        restoreScript(
          preparation: restorePreparation, promptExport: promptExport,
          attachFresh: attachFresh, freshPrefix: markerWrite + "; ", dial: "connect",
          settings: settings)
        + "; exit 255"
    } else {
      connectMissing =
        log("connect", "wait-daemon")
        + #"printf '\033[1;33m── Loop session is not running; waiting for graphcoded "#
        + #"to start it. ──\033[0m\r\n'; exit 255"#
    }
    let connect = delivery + reattachOrRetry("connect") + connectMissing
    let rebootBranch: String
    if loopType == .turnBased {
      rebootBranch =
        #"printf '\033[1;33m── Remote machine rebooted; restoring the session. ──\033[0m\r\n'; "#
        + restoreScript(
          preparation: delivery + restorePreparation, promptExport: promptExport,
          attachFresh: attachFresh, dial: "reboot", settings: settings) + "; exit 255"
    } else {
      rebootBranch =
        log("reboot", "wait-daemon")
        + #"printf '\033[1;33m── Remote machine rebooted; waiting for the loop session "#
        + #"to be restored. ──\033[0m\r\n'; exit 255"#
    }
    let markerFile = RemoteBootMarker.markerExpression(forSessionName: sessionName)
    let reconnect =
      reattachOrRetry("reconnect")
      + "\(RemoteBootMarker.captureFragment); gc_last=$(cat \(markerFile) 2>/dev/null); "
      + "if [ -n \"$gc_boot\" ] && [ -n \"$gc_last\" ] && [ \"$gc_boot\" != \"$gc_last\" ]; then "
      + rebootBranch + "; fi; "
      + log("reconnect", "session-ended")
      + #"printf '\033[2m── Remote session ended while disconnected. ──\033[0m\r\n'; exit 0"#
    return (connect, reconnect)
  }

  /// The turn-based restore a missing session sends both dials into: the preparation
  /// the caller assembled (cd, hooks — the connect's delivery already ran), then
  /// resume-or-fresh.
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
  /// `freshPrefix` runs just before the fresh launch. The connect passes the boot
  /// marker write there — the create is an attach, and a first launch that recorded no
  /// boot would read as "ended while disconnected" on its first real reboot. The
  /// reconnect passes nothing: its restore runs behind a proven reboot, and a marker
  /// rewritten before the session is back would make a drop mid-restore redial into
  /// "same boot" and close the pane on a reboot that was real.
  ///
  /// The trailing `exit 255` in the caller catches a preparation step failing (the
  /// repository directory not mounted yet, a hooks write refused) — the host is
  /// mid-boot, so keep dialing rather than letting it read as "the loop finished".
  private func restoreScript(
    preparation: String, promptExport: String, attachFresh: String, freshPrefix: String = "",
    dial: String, settings: GraphcodeSettings
  ) -> String {
    let log = { (event: String) in
      DialLog.fragment(session: self.sessionName, dial: dial, event: event) + "; "
    }
    var script = preparation + "{ "
    let nodeID = SurfaceRef.nodeID(fromZmxSessionName: sessionName)
    let resumeLaunch = resumeCommand(
      settings: settings,
      remoteSettingsPath: backend == .claudeCode ? PresenceHooks.remotePathExpression : nil)
    if let nodeID, let resumeLaunch {
      let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: nodeID)
      let attempt =
        log("resume")
        + "export \(ZmxSessionLauncher.remoteResumeIDVariable); gc_t0=$(date +%s); "
        + ZmxSessionLauncher.quotedCommand(["zmx", "attach", sessionName] + resumeLaunch)
        + "; gc_rc=$?; [ $(($(date +%s) - gc_t0)) -ge 5 ] && exit \"$gc_rc\"; "
        + log("resume-dead")
        + #"printf '\033[1;33m── Resume did not take; starting the session fresh. ──\033[0m\r\n'"#
      script += ZmxSessionLauncher.resumeOrFreshScript(idFile: idFile, resume: attempt) + "; "
    }
    script += promptExport + freshPrefix + log("fresh") + "exec \(attachFresh); }; fi"
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
  ///
  /// `hooksFile` is the local twin of `remoteSettingsPath` — the presence hooks this
  /// machine wrote. A resumed local session needs them for the same reason a fresh one
  /// does: without them the loop reports IDLE for as long as it runs.
  func resumeCommand(
    settings: GraphcodeSettings, hooksFile: URL? = nil, remoteSettingsPath: String?
  ) -> [String]? {
    guard backend.supportsResume, var parts = launchPrefix(settings: settings) else {
      return nil
    }
    let presence = backend.presenceArguments(
      hooksFile: hooksFile, sessionName: nil,
      zmxPath: ZmxLocator.isInstalled ? ZmxLocator.binaryURL.path : nil
    )
    .map(PresenceHooks.singleQuoted)
    .joined(separator: " ")
    if !presence.isEmpty { parts.append(presence) }
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
