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
    nodeID: UUID = UUID(), backend: CLISessionBackendKind = .claudeCode
  ) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: nodeID,
      sessionName: SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, backend: backend,
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
  func aProvenRebootRestoresTheSessionInsteadOfClosingThePane() throws {
    // A missing session used to close the pane unconditionally, which read a host
    // reboot as "the loop finished": the session died with the machine, the pane gave
    // up, and only relaunching the app brought the loop back. The reconnect line now
    // compares the boot it last attached under (`RemoteBootMarker`) and, when the boot
    // changed, restores the session in place — resuming the backend session whose ID
    // the remote hook banked, with the ID consumed first exactly like the daemon's
    // ensure, so a dead one costs a single fresh launch rather than a trapped loop.
    let nodeID = UUID()
    let view = agentSurface(nodeID: nodeID)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains("boot_id"))
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

  @Test
  func copilotRestoreResumesWithoutANameAndCodexCannotResume() {
    // Copilot's `--name` and `--resume` are mutually exclusive; Codex has no resume at
    // all, so its restore goes straight to the fresh launch.
    let copilot = agentSurface(backend: .copilotCLI)
      .resumeCommand(settings: GraphcodeSettings(), remoteSettingsPath: nil)?
      .joined(separator: " ")
    #expect(copilot?.contains(#"--resume "$GRAPHCODE_RESUME_ID""#) == true)
    #expect(copilot?.contains("--name") == false)
    let codex = agentSurface(backend: .codex)
      .resumeCommand(settings: GraphcodeSettings(), remoteSettingsPath: nil)
    #expect(codex == nil)
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
