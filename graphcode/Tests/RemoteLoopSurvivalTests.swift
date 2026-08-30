import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// Remote loops surviving the network (issue #40): the transport that stops random
/// dial failures (multiplexing), the probes that make the daemon's view of a remote
/// session real, the honest `.unknown` when the link is down, and the rule that a
/// dropped connection may never resolve a loop.
@Suite
struct RemoteLoopSurvivalTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")

  private func goalNode(_ title: String = "Fix") -> LoopNode {
    LoopNode(
      title: title, loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      state: .running)
  }

  // MARK: - Transport

  @Test
  func everySSHInvocationMultiplexesOverOneConnectionPerHost() {
    // N loops × presence+usage+activity per poll tick, each as its own TCP dial and key
    // exchange, is the handshake storm behind sporadic "ssh failed" on healthy
    // networks. One master per host makes every later command a cheap channel.
    let invocation = location.sshInvocation(remoteCommand: "true")
    #expect(invocation.contains("ControlMaster=auto"))
    #expect(invocation.contains { $0.hasPrefix("ControlPath=") && $0.hasSuffix("/%C") })
    #expect(invocation.contains("ControlPersist=43200"))
    // The sockets live under the support directory, whose short path is what keeps
    // `ControlPath` inside Darwin's 104-byte `sun_path`.
    let controlPath = invocation.first { $0.hasPrefix("ControlPath=") } ?? ""
    #expect(controlPath.contains("/ssh/"))
  }

  // MARK: - The status probe

  @Test
  func aProbeAsksExistenceAndOneLabelInOneRoundTrip() throws {
    let node = goalNode()
    let invocation = ZmxSessionLauncher.remoteStatusInvocation(
      forNode: node, label: "presence", at: location)

    #expect(invocation.first == "/usr/bin/ssh")
    // A query must not take a tty.
    #expect(!invocation.contains("-t"))
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains(ZmxSessionLauncher.remoteProbeMarker))
    #expect(remoteCommand.contains("'get'"))
    #expect(remoteCommand.contains("presence"))
    #expect(
      remoteCommand.contains(SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName))
  }

  @Test
  func probeOutputSeparatesTheLinkFromTheSession() {
    let marker = ZmxSessionLauncher.remoteProbeMarker
    // ssh failed: nothing about the session is known — and a probe that "succeeded"
    // without ever printing the marker didn't run, which is the same non-answer.
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: false, output: "\(marker) absent")
        == .unreachable)
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: true, output: "motd noise")
        == .unreachable)
    // ssh answered: the marker line is the fact, and `~/.zshrc` chatter before it is
    // ignored.
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(
        succeeded: true, output: "Welcome to build-box!\r\n\(marker) absent\r\n")
        == .absent)
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: true, output: "\(marker) live busy")
        == .live(label: "busy"))
    #expect(
      ZmxSessionLauncher.parseRemoteStatus(succeeded: true, output: "\(marker) live")
        == .live(label: nil))
  }

  @Test
  func presenceDegradesToUnknownNeverToStopped() {
    let fallback = PresenceReading(presence: .idle, confidence: .heuristic)
    #expect(
      ZmxSessionLauncher.presenceReading(from: .unreachable, liveWithoutLabel: fallback)
        == .unknown)
    #expect(
      ZmxSessionLauncher.presenceReading(from: .absent, liveWithoutLabel: fallback)
        == .absent)
    #expect(
      ZmxSessionLauncher.presenceReading(from: .live(label: "busy"), liveWithoutLabel: fallback)
        == PresenceReading(presence: .busy, confidence: .reported))
    // Live with nothing reported is the caller's per-backend fallback, not a guess here.
    #expect(
      ZmxSessionLauncher.presenceReading(from: .live(label: nil), liveWithoutLabel: fallback)
        == fallback)
  }

  @Test
  func anUnknownReadingLeavesTheGraphsBeliefOnScreen() {
    var node = goalNode()
    node.presence = .unknown
    // The probe observed nothing, so the card shows what the graph believes — exactly
    // as if no reading existed. `.absent` would have flipped it to IDLE.
    #expect(node.displayState == .running)
  }

  // MARK: - A disconnect must not resolve the loop

  private func remoteStore(
    presence: @escaping @Sendable (LoopNode, String?) async -> PresenceReading
  ) async -> GraphStore {
    var graph = LoopGraph(
      scope: LoopGraphScope(projectPath: location.projectPath, name: "widget"))
    graph.nodes.append(goalNode())
    return GraphStore(graph: graph, onReadPresence: presence)
  }

  @Test
  func aSurfaceExitWithTheSessionStillLiveResolvesNothing() async {
    // The pane's process ending is a claim relayed over the very link whose failure is
    // being handled — ghostty has no exit-code plumbing, so a reconnect loop giving up
    // looks exactly like the agent finishing. The session itself is the authority.
    let store = await remoteStore(presence: { _, _ in
      PresenceReading(presence: .busy, confidence: .reported)
    })
    let nodeID = await store.graph.nodes.first!.id

    await store.handle(.nodeCheckApproved(nodeID))

    #expect(await store.graph.nodes.first?.state == .running)
  }

  @Test
  func aSurfaceExitWithTheHostUnreachableResolvesNothing() async {
    let store = await remoteStore(presence: { _, _ in .unknown })
    let nodeID = await store.graph.nodes.first!.id

    await store.handle(.nodeCheckApproved(nodeID))
    await store.handle(.nodeCheckRejected(nodeID))

    #expect(await store.graph.nodes.first?.state == .running)
  }

  @Test
  func aConfirmedAbsentSessionResolvesAsUsual() async {
    // ssh answered and the session is gone: that is the loop finishing while
    // disconnected, and it resolves exactly as a local exit would.
    let store = await remoteStore(presence: { _, _ in .absent })
    let nodeID = await store.graph.nodes.first!.id

    await store.handle(.nodeCheckApproved(nodeID))

    #expect(await store.graph.nodes.first?.state == .succeeded)
  }

  @Test
  func aLocalProjectNeverPaysForTheProbe() async {
    // The guard is remote-only: a local surface owned its process, and its exit needs
    // no second opinion — asking would add latency to every resolution there is.
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/widget", name: "widget"))
    graph.nodes.append(goalNode())
    let store = GraphStore(
      graph: graph,
      onReadPresence: { _, _ in
        Issue.record("a local resolution must not probe")
        return .unknown
      })
    let nodeID = await store.graph.nodes.first!.id

    await store.handle(.nodeCheckApproved(nodeID))

    #expect(await store.graph.nodes.first?.state == .succeeded)
  }

  // MARK: - The reconnect line

  private func agentSurface(
    nodeID: UUID = UUID(), backend: CLISessionBackendKind = .claudeCode,
    loopType: LoopType = .turnBased
  ) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: nodeID,
      sessionName: SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, backend: backend, loopType: loopType,
      initialPrompt: "fix the build", workingDirectory: location.projectPath,
      projectPath: location.projectPath, onProcessExited: { _ in })
  }

  @Test
  func onlyAnExplicitNoSuchSessionMayEndThePane() throws {
    // `zmx get` exits 1 for a missing session. Any other failure — `command not found`
    // while the host boots, a broken login shell after wake — says nothing about the
    // session, so it re-enters the retry loop (exit 255) instead of closing the pane
    // and resolving the loop.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains(#"-ne 1"#))
    #expect(loopBody.contains("exit 255"))
    #expect(loopBody.contains("ended while disconnected"))
  }

  // MARK: - Reboot restore

  @Test
  func aProvenRebootRestoresATurnBasedSessionInsteadOfClosingThePane() throws {
    // A missing session used to close the pane unconditionally, which read a host
    // reboot as "the loop finished": the session died with the machine, the pane gave
    // up, and only relaunching the app brought the loop back. For a turn-based loop —
    // the one kind the daemon never restores — the reconnect line now compares the boot
    // it last attached under (`RemoteBootMarker`) and, when the boot changed, restores
    // the session itself: resume from the banked ID, consumed first exactly like the
    // daemon's ensure.
    let nodeID = UUID()
    let view = agentSurface(nodeID: nodeID)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains("boot_id"))
    #expect(loopBody.contains("kern.bootsessionuuid"))
    #expect(loopBody.contains(".graphcode/boots/graphcode-\(nodeID.uuidString)"))
    #expect(loopBody.contains(#"[ "$gc_boot" != "$gc_last" ]"#))
    #expect(loopBody.contains("\(nodeID.uuidString).id"))
    #expect(loopBody.contains(#"--resume "$GRAPHCODE_RESUME_ID""#))
    #expect(loopBody.contains("rm -f"))
    // Same boot — or no boot to compare — still closes with the notice: a session that
    // ended on its own must not be relaunched behind the human's back.
    #expect(loopBody.contains("ended while disconnected"))
  }

  @Test
  func aDeadResumeIDFallsThroughToAFreshLaunchInsteadOfClosingThePane() throws {
    // `claude --resume` against a pruned transcript exits immediately, and `zmx attach`
    // passes that exit straight to ssh — a non-255 code the outer loop would close the
    // pane on. Only this attached script can see how long the session lived, so the
    // restore measures: an attach back in under five seconds is a dead ID and falls
    // through to the fresh launch; one that lived was a real session whose exit passes
    // through as ever.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains("gc_t0=$(date +%s)"))
    #expect(loopBody.contains("-ge 5"))
    #expect(loopBody.contains("Resume did not take"))
  }

  @Test
  func anUnattendedLoopDefersItsRestoreToTheDaemon() throws {
    // The daemon's liveness sweep already restores an unattended loop's session, with
    // the resume ID and the ensure gate. The pane joining in raced it: both consumed
    // the same ID file, and the loser's read came back empty, so the loop restarted
    // fresh instead of resuming (the bug observed in the field). After a proven reboot
    // the pane only announces and keeps dialing; the reattach branch joins the session
    // the moment the sweep has it back. No resume, no ID consumption, no prompt
    // re-export — nothing for the daemon to race.
    let view = agentSurface(loopType: .goalBased)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains(#"[ "$gc_boot" != "$gc_last" ]"#))
    #expect(loopBody.contains("waiting for the loop session"))
    #expect(!loopBody.contains("--resume"))
    #expect(!loopBody.contains("rm -f"))
    #expect(!loopBody.contains("GRAPHCODE_TRIGGER_PROMPT"))
    #expect(loopBody.contains("ended while disconnected"))
  }

  @Test
  func theRestoreDoesNotRefreshTheMarkerUntilASessionIsLive() throws {
    // The marker updates only when an attach finds a live session. Written during the
    // restore, a drop mid-restore would make the next redial read "same boot" and
    // close the pane as "ended while disconnected" on a reboot that was real.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    let rebootCheck = try #require(loopBody.range(of: #"[ "$gc_boot" != "$gc_last" ]"#))
    #expect(!loopBody[rebootCheck.upperBound...].contains("mkdir -p \"$HOME/.graphcode/boots\""))
  }

  @Test
  func everyAttachRecordsTheBootItHappenedUnder() throws {
    // The connect line writes the marker the reconnect line will later compare, and a
    // plain reattach refreshes it — a marker left stale across a survived reboot would
    // make the *next* ordinary session end read as another reboot and resume a
    // conversation that had finished.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let splitAt = try #require(script.range(of: "while :; do"))
    let connectLine = script[..<splitAt.lowerBound]
    let loopBody = script[splitAt.upperBound...]
    #expect(connectLine.contains(".graphcode/boots"))
    let reattach = try #require(loopBody.range(of: "-eq 0"))
    let successBranch = loopBody[reattach.upperBound...]
    let branchEnd = try #require(successBranch.range(of: "fi;"))
    #expect(successBranch[..<branchEnd.lowerBound].contains(".graphcode/boots"))
  }

  // MARK: - The connect dial

  @Test
  func theConnectProbesBeforeItWillCreateAnything() throws {
    // The connect used to be a bare create-or-attach carrying the goal prompt, which
    // held only while one surface process survived a whole outage: surfaces are
    // LRU-retained, and one rebuilt while a remote reboot had the session down — a
    // screen switch, an app relaunch, reopening the loop — re-ran the goal from
    // scratch and rebanked a fresh session ID over the one holding the work. Both
    // dials now open with the same probe.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let connectLine = try #require(script.range(of: "while :; do").map { script[..<$0.lowerBound] })
    #expect(connectLine.contains("'get'"))
    #expect(connectLine.contains(#"-ne 1"#))
    #expect(connectLine.contains("exit 255"))
  }

  @Test
  func aLiveSessionIsJoinedWithoutTheAgentCommand() throws {
    // A live session means someone already launched the agent — the daemon's ensure or
    // an earlier pane. Attaching with the launch argv would be harmless today only
    // because zmx ignores it; joining plainly makes that not depend on zmx's mercy.
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let connectLine = try #require(script.range(of: "while :; do").map { script[..<$0.lowerBound] })
    let live = try #require(connectLine.range(of: "-eq 0"))
    let branchEnd = try #require(connectLine[live.upperBound...].range(of: "fi;"))
    let branch = connectLine[live.upperBound..<branchEnd.lowerBound]
    #expect(branch.contains("exec"))
    #expect(branch.contains(".graphcode/boots"))
    #expect(!branch.contains("claude"))
    #expect(!branch.contains("GRAPHCODE_TRIGGER_PROMPT"))
  }

  @Test
  func anUnattendedConnectNeverCarriesThePromptAndWaitsForTheDaemon() throws {
    // An unattended loop's session is graphcoded's to start — at node creation, at
    // graph load, and every liveness sweep, under the ensure gate. The pane creating
    // it here raced that ensure: whichever launched second either re-ran the goal or
    // typed a launch command into the other's session. The pane now announces and
    // keeps dialing until the daemon has it.
    let view = agentSurface(loopType: .goalBased)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(!script.contains("GRAPHCODE_TRIGGER_PROMPT"))
    #expect(!script.contains("--append-system-prompt"))
    #expect(!script.contains("--resume"))
    let connectLine = try #require(script.range(of: "while :; do").map { script[..<$0.lowerBound] })
    #expect(connectLine.contains("waiting for graphcoded"))
    #expect(connectLine.contains("exit 255"))
  }

  @Test
  func aTurnBasedConnectResumesTheBankedConversation() throws {
    // Opening a remote turn-based loop whose session was gone used to restart the
    // goal fresh — the resume-on-open the local pane got never reached the remote
    // dial. The connect's missing branch now runs the same consume-first restore as
    // the reconnect's proven-reboot branch; only a loop nothing ever banked an ID for
    // falls through to the prompt-bearing first launch, which records the boot it
    // was created under.
    let nodeID = UUID()
    let view = agentSurface(nodeID: nodeID)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let connectLine = try #require(script.range(of: "while :; do").map { script[..<$0.lowerBound] })
    #expect(connectLine.contains("\(nodeID.uuidString).id"))
    #expect(connectLine.contains(#"--resume "$GRAPHCODE_RESUME_ID""#))
    #expect(connectLine.contains("rm -f"))
    #expect(connectLine.contains("GRAPHCODE_TRIGGER_PROMPT"))
    let fresh = try #require(connectLine.range(of: "Resume did not take"))
    #expect(connectLine[fresh.upperBound...].contains(".graphcode/boots"))
  }

  @Test
  func aCopilotPaneBanksTheResumeIDOnEveryLiveJoin() throws {
    // A turn-based Copilot loop never gets an ensure dial, so the pane's attach-live
    // branch is its one chance to bank — same fragment, same `[ -s ]` guard.
    let view = agentSurface(backend: .copilotCLI)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(script.contains("session-state"))
    #expect(script.contains("bank copilot-id"))
    let claude = agentSurface()
    let claudeScript = try #require(
      claude.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(!claudeScript.contains("session-state"))
  }

  @Test
  func copilotAndCodexRestoreWithTheirOwnResumeSyntax() {
    // Copilot's `--name` and `--resume` are mutually exclusive. Codex resumes through
    // its subcommand and the notifier banks the next thread ID under this remote node.
    let copilot = agentSurface(backend: .copilotCLI)
      .resumeCommand(settings: GraphcodeSettings(), remoteSettingsPath: nil)?
      .joined(separator: " ")
    #expect(copilot?.contains(#"--resume "$GRAPHCODE_RESUME_ID""#) == true)
    #expect(copilot?.contains("--name") == false)
    let codex = agentSurface(backend: .codex)
      .resumeCommand(settings: GraphcodeSettings(), remoteSettingsPath: nil, isRemote: true)?
      .joined(separator: " ")
    #expect(codex?.contains(#"resume "$GRAPHCODE_RESUME_ID""#) == true)
    #expect(codex?.contains("$HOME/.graphcode/sessions") == true)
  }

  // MARK: - Remote presence hooks

  @Test
  func aRemoteClaudeLaunchWritesHooksThereAndPointsAtThem() throws {
    // Without hooks on the host, a busy remote loop reads IDLE forever — the very
    // wrong-state the issue names. The ensure writes them where they run, and the
    // launch line references them as a `$HOME` only the remote shell can expand.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("mkdir -p"))
    #expect(remoteCommand.contains(".graphcode/hooks"))
    #expect(remoteCommand.contains("claude-code.json"))
    #expect(remoteCommand.contains("--settings"))
    // The hooks report through the remote host's own PATH-resolved zmx, not a local
    // binary path that means nothing there.
    #expect(!remoteCommand.contains(ZmxLocator.binaryURL.path))
  }

  @Test
  func theAppsRemoteAttachWritesTheSameHooks() throws {
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(script.contains("claude-code.json"))
    #expect(script.contains("--settings"))
    // The reconnect line configures nothing on a plain reattach — hooks appear in its
    // restore branch alone, which recreates the session and so writes them the way the
    // connect line does, behind the boot comparison that proves recreating is safe.
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    let hooksInLoop = try #require(loopBody.range(of: "claude-code.json"))
    let rebootCheck = try #require(loopBody.range(of: #"[ "$gc_boot" != "$gc_last" ]"#))
    #expect(rebootCheck.upperBound <= hooksInLoop.lowerBound)
  }
}
