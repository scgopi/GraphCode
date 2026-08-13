import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// A remote host rebooting — a Codespace idle-stopping and starting again — and what
/// happens to the loops running on it.
///
/// Local loops were covered from the start: the machine coming back restarts
/// `graphcoded`, which loads the graph, calls `ensureUnattendedSessions`, and resumes
/// each backend session from the ID a `SessionStart` hook persisted. Every link in that
/// chain was local-only. The remote host reboots without this daemon restarting, so
/// nothing re-ensured; `resumeArguments` refused remote outright; and the hook installed
/// on the remote named *this Mac's* `/Users/<me>/.graphcode`, a path a Codespace cannot
/// even create. Loops sat dead until the app was relaunched, and then started over from
/// their opening prompt.
@Suite
struct RemoteSessionResumeTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "codespace", port: 2222, remotePath: "/workspaces/widget")

  private func goalNode(_ backend: CLISessionBackendKind = .claudeCode) -> LoopNode {
    LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      backend: backend, state: .running)
  }

  /// The `SessionStart` capture command, dug out of the settings JSON.
  private func captureCommand(sessionsDirectory: String? = nil) throws -> String {
    let json = try #require(
      PresenceHooks.json(
        forBackend: .claudeCode, zmxPath: "/opt/zmx", sessionsDirectory: sessionsDirectory))
    let parsed =
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    let hooks = try #require(parsed["hooks"] as? [String: Any])
    let matchers = try #require(hooks["SessionStart"] as? [[String: Any]])
    let entries = try #require(matchers.first?["hooks"] as? [[String: Any]])
    let commands = entries.compactMap { $0["command"] as? String }
    return try #require(commands.first { $0.contains("CLAUDE_CODE_SESSION_ID") })
  }

  // MARK: - Capturing the ID on the host that will read it

  @Test
  func aRemoteHookWritesTheSessionIDIntoTheRemoteHomeDirectory() throws {
    let command = try captureCommand(sessionsDirectory: PresenceHooks.remoteSessionsExpression)

    // A `$HOME` expression, not a path: only a shell on that machine knows its home
    // directory. The hook used to carry this Mac's absolute path, so on a Codespace it
    // tried to `mkdir -p /Users/<me>/.graphcode/sessions` as a non-root user and wrote
    // nothing at all — which is why no remote loop ever had an ID to resume from.
    #expect(command.contains("mkdir -p \"$HOME/.graphcode/sessions\""))
    #expect(command.contains("\"$HOME/.graphcode/sessions\"/\"$node_id\".id"))
    #expect(!command.contains(SupportDirectory.url.path))
  }

  @Test
  func theLocalHookStillWritesWhereTheLocalStoreReads() throws {
    // The regression guard on the other side of the same change: `SessionIDStore.load`
    // reads an absolute path on this disk, so the local hook must keep naming it.
    let command = try captureCommand()
    let sessions = SupportDirectory.url.appendingPathComponent("sessions", isDirectory: true)

    #expect(command.contains(sessions.path))
    #expect(!command.contains("$HOME"))
  }

  @Test
  func theRemoteFragmentInstallsTheRemoteFlavourOfTheHooks() throws {
    let fragment = try #require(PresenceHooks.remoteWriteFragment())
    // `JSONEncoder` escapes forward slashes, and the fragment carries the settings file
    // as raw JSON — so read the paths back the way the hook's own JSON parser will.
    let unescaped = fragment.replacingOccurrences(of: "\\/", with: "/")

    #expect(fragment.contains(PresenceHooks.remotePathExpression))
    #expect(unescaped.contains("$HOME/.graphcode/sessions"))
    #expect(!unescaped.contains(SupportDirectory.url.path))
    // Still never load-bearing: a host that can't take the write gets the heuristic
    // presence, not a failed launch.
    #expect(fragment.contains("|| true"))
  }

  // MARK: - Reading it back, on the host

  @Test
  func aRemoteEnsureResumesFromTheIDTheRemoteHookLeftBehind() throws {
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    // The ID is read on the host, because that is the only side that has it:
    // `SessionIDStore` reads this Mac's disk, where a remote loop's ID has never been
    // written.
    #expect(
      remoteCommand.contains(
        "cat \(PresenceHooks.remoteSessionIDExpression(forNodeID: node.id))"))
    #expect(remoteCommand.contains("$HOME/.graphcode/sessions"))
    #expect(remoteCommand.contains(node.id.uuidString))
    #expect(remoteCommand.contains("'--resume'"))
    // As a variable reference, not a literal — this machine cannot know the value.
    #expect(remoteCommand.contains("\"$GRAPHCODE_RESUME_ID\""))
    #expect(!remoteCommand.contains(ZmxSessionLauncher.remoteResumeIDPlaceholder))
  }

  @Test
  func anAbsentIDFallsBackToTheOpeningPrompt() throws {
    // A first launch, and a Codespace *rebuild*: everything outside /workspaces is gone,
    // so the transcript `--resume` would name went with the ID file. Starting fresh is
    // the right answer for both.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    #expect(remoteCommand.contains("; else "))
    // The opening prompt is still there, on the branch taken when the `cat` came back
    // empty — and it comes after the resume, which is the branch order the `if` states.
    let resume = try #require(remoteCommand.range(of: "--resume"))
    let goal = try #require(remoteCommand.range(of: "tests pass"))
    #expect(resume.lowerBound < goal.lowerBound)
  }

  @Test
  func aResumeConsumesTheIDSoADeadOneCannotTrapTheLoop() throws {
    // An ID whose transcript has expired makes `claude --resume` exit at once, and
    // nothing clears the remote file: `kill` removes only the local one, and the remote
    // path returns before reaching it. Left in place, the sweep would retry the same
    // dead ID every minute and never reach the fresh branch again. Testing the exit
    // status cannot help — `zmx run -d` returns 0 as soon as the detached session
    // exists, long before the agent inside it fails — so the file is removed up front.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    let idFile = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
    #expect(remoteCommand.contains("rm -f \(idFile)"))
    let removal = try #require(remoteCommand.range(of: "rm -f"))
    let resume = try #require(remoteCommand.range(of: "--resume"))
    #expect(removal.lowerBound < resume.lowerBound)
  }

  @Test
  func theReaderAndTheWriterNameTheSameDirectory() {
    // Divergence here would not fail loudly: every remote resume would fall silently
    // through to the opening prompt, which is the bug this path exists to end.
    #expect(
      PresenceHooks.remoteSessionIDExpression(forNodeID: UUID())
        .hasPrefix(PresenceHooks.remoteSessionsExpression))
  }

  @Test
  func theHooksWriteRunsOnlyWhenASessionIsBeingCreated() throws {
    // Claude Code reads `--settings` once at startup, so rewriting the hooks file for a
    // session that is already running does nothing — and at one dial a minute it is a
    // `python3` and a `printf` per loop for a file nothing will re-read.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    // Anchored on the write itself, not on the path: `.graphcode/hooks` also appears in
    // the launch argv as `--settings "$HOME/.graphcode/hooks/claude-code.json"`, so this
    // assertion would pass with the write deleted entirely.
    let write = try #require(remoteCommand.range(of: "mkdir -p \"$HOME/.graphcode/hooks\""))
    // And inside the create branch, not merely after the check — textual order alone
    // would be satisfied by a fragment sitting outside the group.
    let branch = try #require(remoteCommand.range(of: ">/dev/null 2>&1 || { "))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(branch.lowerBound < write.lowerBound)
    #expect(write.lowerBound < run.lowerBound)
  }

  @Test
  func theShimIsRedeliveredWhenTheHostsCopyIsStaleEvenIfTheSessionIsLive() throws {
    // The one delivered file that cannot follow the hooks behind the check: the agent
    // re-executes the shim for as long as the session lives, and it speaks a wire
    // protocol to this daemon. A graphcode upgrade that never reaches a host whose loops
    // are still running breaks `graphcode node send`/`memo`/`resolve` for all of them —
    // and an unattended loop has no human to open it and heal the delivery.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    #expect(remoteCommand.contains(RemoteGraphAccess.cliShimStamp))
    #expect(remoteCommand.contains("cat \(RemoteGraphAccess.shimStampPath)"))
    // Session missing *or* stamp differs — a fresh launch must re-deliver whatever the
    // stamp says, because the argv it is about to run names the briefing, wake digest
    // and prompt files that ride in this same fragment.
    let gate = try #require(remoteCommand.range(of: "if ! "))
    let deliver = try #require(remoteCommand.range(of: "b64decode"))
    #expect(gate.lowerBound < deliver.lowerBound)
  }

  @Test
  func aFailedDeliveryLeavesNoStampBehind() throws {
    // Two failure modes, one rule: the stamp is a receipt, so it must be written last
    // and only on success.
    //
    // Stamping from the shell after the installer doesn't work — `installerScript` ends
    // in `|| true`, so a host with no `python3` would be marked current with nothing
    // installed. Nor does putting it in the manifest: that comprehension is not
    // transactional and iterates `sorted(m.items())`, where `.` sorts before `g`, so
    // `.shim-stamp` would land *before* `graphcode` and a host whose shim write fails
    // (one owned by another uid, under a directory that is writable) would claim a CLI
    // it never received. Both leave the host permanently un-upgradeable, because the
    // matching stamp then skips every later delivery.
    let script = try #require(
      ZmxSessionLauncher.remoteDeliveryScript(
        forNode: nil, at: location, settings: GraphcodeSettings()))

    #expect(!script.contains("printf"))

    // Not a manifest entry — the manifest is the one token that base64-decodes to JSON.
    let files = try #require(
      script.split(whereSeparator: { $0 == " " || $0 == "'" })
        .compactMap { Data(base64Encoded: String($0)) }
        .compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        .first)
    #expect(files[RemoteGraphAccess.cliInstallPath] != nil)
    #expect(files[RemoteGraphAccess.shimStampPath] == nil)

    // Written by a statement that follows the comprehension, so a raise anywhere inside
    // it skips the receipt entirely.
    let write = try #require(script.range(of: "open(os.path.expanduser(sys.argv[2])"))
    let comprehension = try #require(script.range(of: "for p,c in sorted(m.items())]"))
    #expect(comprehension.upperBound < write.lowerBound)
    #expect(script.contains(RemoteGraphAccess.shimStampPath))
    #expect(script.contains(RemoteGraphAccess.cliShimStamp))
  }

  @Test
  func theShimStampIsStableAcrossProcesses() {
    // Swift's own `hashValue` is seeded per process, which would report the shim as
    // changed on every daemon restart and re-deliver it forever.
    #expect(RemoteGraphAccess.cliShimStamp == RemoteGraphAccess.cliShimStamp)
    #expect(!RemoteGraphAccess.cliShimStamp.isEmpty)
  }

  @Test
  func theExistenceCheckStillGuardsBothBranches() throws {
    // The create-only property the one-shell ensure exists for: a live session must not
    // be relaunched *or* resumed. Both are behind the same `zmx get`.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    let get = try #require(remoteCommand.range(of: "'get'"))
    let resume = try #require(remoteCommand.range(of: "--resume"))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(get.lowerBound < resume.lowerBound)
    #expect(get.lowerBound < run.lowerBound)
    #expect(remoteCommand.contains("||"))
  }

  @Test
  func aRemoteResumeNamesTheRemoteHooksAndNoLocalPaths() throws {
    let node = goalNode()
    let argv = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: node, sessionID: ZmxSessionLauncher.remoteResumeIDPlaceholder,
        projectPath: location.projectPath))

    // The same three things `arguments(forNode:)` branches on for remote: hooks named as
    // a `$HOME` expression the remote shell expands, no local zmx to report to, and no
    // path from this machine anywhere in the argv.
    #expect(argv.contains { $0.contains("--settings \"$HOME/.graphcode/hooks/claude-code.json\"") })
    #expect(!argv.contains { $0.contains(SupportDirectory.url.path) })
  }

  // MARK: - Local resume, unchanged

  @Test
  func aLocalResumeStillCarriesItsLiteralIDAndLocalHooks() throws {
    let node = goalNode()
    let argv = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: node, sessionID: "abc-123", projectPath: "/Users/dev/widget"))

    #expect(argv.contains("--resume"))
    #expect(argv.contains("abc-123"))
    // No remote hooks suffix leaked onto the local path — the `$HOME` there would be
    // this machine's, and the file it names is written by absolute path.
    #expect(!argv.contains { $0.contains("$HOME") })
  }

  @Test
  func aCopilotEnsureBanksTheLiveSessionsResumeID() throws {
    // Copilot has no hooks, so nothing banked its resume ID on the remote host and a
    // host reboot restarted every Copilot loop's goal from scratch (the first
    // dial-logged incident, 2026-08-13: three `reboot wait-daemon` → `ensure fresh`).
    // The ensure now banks the ID from the session-state directory while the session
    // is alive, and the whole existing resume machinery takes over on the next reboot.
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: goalNode(.copilotCLI), at: location))
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("session-state"))
    #expect(remoteCommand.contains("workspace.yaml"))
    #expect(remoteCommand.contains(".history"))
    #expect(remoteCommand.contains("[ -s"))
    #expect(remoteCommand.contains("bank copilot-id"))
    // The bank rides the alive branch: behind the existence check, before the create —
    // and it must always exit 0, or an alive tick would fall into the create branch.
    let check = try #require(remoteCommand.range(of: "'get'"))
    let bank = try #require(remoteCommand.range(of: "session-state"))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(check.upperBound <= bank.lowerBound)
    #expect(bank.upperBound <= run.lowerBound)
    #expect(remoteCommand.contains("|| true"))
  }

  @Test
  func aClaudeEnsureNeverWalksCopilotState() throws {
    // Claude banks through its own SessionStart hook; scanning Copilot's directory for
    // it would be a wasted walk on every claude create.
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: goalNode(), at: location))
    #expect(!(try #require(invocation.last)).contains("session-state"))
  }

  @Test
  func aCodexNodeHasNoResumeToOffer() {
    // Codex has no `--resume` graphcode has spiked, so the remote ensure keeps the
    // single fresh-launch branch rather than inventing a flag.
    #expect(
      ZmxSessionLauncher.resumeArguments(
        forNode: goalNode(.codex), sessionID: "abc-123", projectPath: location.projectPath)
        == nil)
  }

  // MARK: - One ensure per node

  @Test
  func aSecondEnsureForTheSameNodeIsRefusedWhileOneIsInFlight() async throws {
    // Two dials whose checks both miss both run, and the second types the whole launch
    // command into the agent the first one started.
    let gate = RemoteEnsureGate()
    let node = UUID()

    let lease = try #require(await gate.begin(node))
    #expect(await gate.begin(node) == nil)
    #expect(await gate.begin(UUID()) != nil)

    await gate.end(node, token: lease)
    #expect(await gate.begin(node) != nil)
  }

  @Test
  func aWedgedDialCannotSilenceItsNodeForever() async {
    // The reason this is a lease and not a `Set`. `runRemoteRetrying` →
    // `PTYProcessSession.waitCollectingOutput` ends only when the child's
    // `terminationHandler` finishes the stream, and there is no timeout in the chain —
    // ssh blocked on a wedged `ControlMaster` socket never returns, so `end` is never
    // reached. A flag would leave that node refused for the daemon's lifetime, which is
    // a worse failure than the double-launch it prevents.
    let gate = RemoteEnsureGate()
    let node = UUID()
    let start = Date()

    #expect(await gate.begin(node, now: start) != nil)
    #expect(await gate.begin(node, now: start.addingTimeInterval(60)) == nil)
    #expect(
      await gate.begin(
        node, now: start.addingTimeInterval(RemoteEnsureGate.leaseDuration + 1)) != nil)
  }

  @Test
  func aRecoveredWedgeCannotReleaseSomeoneElsesLease() async throws {
    // The race an unconditional `removeValue` loses: dial A wedges and its lease
    // expires, dial B takes a fresh one, then A's ssh finally returns. If A's `end`
    // cleared B's lease, the next sweep tick would start a third dial alongside B — and
    // with the host having just come back, both would miss on `zmx get` and both would
    // `zmx run`, which is the composer-bar leak the gate exists to prevent.
    let gate = RemoteEnsureGate()
    let node = UUID()
    let start = Date()

    let wedged = try #require(await gate.begin(node, now: start))
    let expired = start.addingTimeInterval(RemoteEnsureGate.leaseDuration + 1)
    let fresh = try #require(await gate.begin(node, now: expired))

    // A returns late and tries to clean up after itself.
    await gate.end(node, token: wedged)

    // B still holds the gate.
    #expect(await gate.begin(node, now: expired.addingTimeInterval(60)) == nil)
    await gate.end(node, token: fresh)
    #expect(await gate.begin(node, now: expired.addingTimeInterval(61)) != nil)
  }

  // MARK: - Noticing the reboot at all

  @Test
  func theLivenessSweepRestartsUnattendedLoopsWithoutRearmingPollers() async {
    // The sweep is what makes any of the above run: a remote host reboots while this
    // daemon keeps going, so `ensureUnattendedSessions`'s one call site — loading a
    // persisted graph — never fires again.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })
    await store.handle(
      .createNode(NodeDraft(title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check")))
    await store.handle(
      .createNode(
        NodeDraft(title: "Green", loopType: .goalBased, goal: GoalSpec(summary: "CI passes"))))
    await store.handle(
      .createNode(
        NodeDraft(title: "Read", loopType: .turnBased, checkDescription: "Sound?")))
    started.withValue { $0.removeAll() }

    await store.ensureUnattendedSessionsAlive()

    #expect(started.value.count == 2)
    #expect(Set(started.value.map(\.loopType)) == [.timeBased, .goalBased])
  }

  @Test
  func theLivenessSweepLeavesAStoppedLoopStopped() async {
    // The one place the sweep is deliberately stricter than the load-time ensure, which
    // restarts a `.stopped` time-based node. Defensible once at boot; every minute it
    // would mean a human who stopped a remote loop watches it come back.
    let started = LockIsolated<[LoopNode]>([])
    let node = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check", state: .stopped)
    let store = GraphStore(
      graph: LoopGraph(
        scope: LoopGraphScope(projectPath: location.projectPath, name: "widget"),
        nodes: [node]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.ensureUnattendedSessionsAlive()

    #expect(started.value.isEmpty)
  }
}
