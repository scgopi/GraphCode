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
    // And inside the create-only branch (behind the `zmx get` hint), not merely after
    // something — textual order alone would be satisfied by a fragment sitting outside
    // the gate. The write sits ahead of the liveness listing, so nothing can come between
    // that listing and the launch.
    let get = try #require(remoteCommand.range(of: "'get'"))
    let check = try #require(remoteCommand.range(of: "ls 2>/dev/null"))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(get.lowerBound < write.lowerBound)
    #expect(write.lowerBound < check.lowerBound)
    #expect(check.lowerBound < run.lowerBound)
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
    // The delivery is decided by the host's receipt alone — never by the session — so a
    // fresh launch re-delivers whatever the receipt says is stale, and a pane that creates
    // the session mid-delivery cannot turn a stale listing into a launch.
    let gate = try #require(
      remoteCommand.range(of: "if [ \"$(cat \(RemoteGraphAccess.shimStampPath)"))
    let deliver = try #require(remoteCommand.range(of: "b64decode"))
    #expect(gate.lowerBound < deliver.lowerBound)
    #expect(!remoteCommand[gate.lowerBound..<deliver.lowerBound].contains("'zmx'"))
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

    // `printf` does appear in the fragment now — a failed delivery reports its reason to
    // the host's dial log — so this asserts the rule the old `!contains("printf")` line
    // stood for: no shell redirect in here names the stamp. Checking the *redirect* and
    // not merely "every printf mentions dials.log" is deliberate; the loose form passes a
    // rogue `printf 'stamp' > …/.shim-stamp;` because the text after it picks up
    // `dials.log` from the next fragment's own trim.
    // Matching the literal tilde spelling is not enough: `$HOME/.graphcode/...` is this
    // codebase's own spelling for that directory (`DialLog.logExpression` uses it), so a
    // future author writing the stamp the way the dial log is written would walk past a
    // literal check. Nor is `"> " + path`, which two spaces or an fd defeat. This matches
    // any redirect at any target ending in the stamp's name — and does not flag the real
    // fragment, where `.shim-stamp` appears only as a quoted argv token.
    #expect(
      script.range(
        of: #"[0-9]?>>?\s*[^\s;|&]*\.shim-stamp"#, options: .regularExpression) == nil)
    // And the only thing any append in the fragment targets is the dial log.
    #expect(
      script.components(separatedBy: ">> ").dropFirst()
        .allSatisfy { $0.hasPrefix(DialLog.logExpression) })

    // Not a manifest entry — the manifest is the one token that decodes to JSON.
    let files = try #require(
      script.split(whereSeparator: { $0 == " " || $0 == "'" })
        .compactMap { RemoteGraphAccess.manifest(fromInstallerArgument: String($0)) }
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
  func theAliveCheckStillGuardsBothBranches() throws {
    // The create-only property the one-shell ensure exists for: a live session must not
    // be relaunched *or* resumed. Both are behind the same alive check — which, unlike
    // raw existence, a husk does not pass (#215): a session whose task has ended has to
    // fall through to the run, or a dead loop could never be woken.
    let node = goalNode()
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    let check = try #require(remoteCommand.range(of: "ls 2>/dev/null"))
    let resume = try #require(remoteCommand.range(of: "--resume"))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(check.lowerBound < resume.lowerBound)
    #expect(check.lowerBound < run.lowerBound)
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
    // The bank rides the alive branch: behind the alive check, before the create —
    // and it must always exit 0, or an alive tick would fall into the create branch.
    let check = try #require(remoteCommand.range(of: "ls 2>/dev/null"))
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
  func aCodexNodeUsesItsResumeSubcommand() throws {
    let arguments = try #require(
      ZmxSessionLauncher.resumeArguments(
        forNode: goalNode(.codex), sessionID: "abc-123", projectPath: location.projectPath))
    #expect(arguments.contains { $0.contains("resume") })
    #expect(arguments.contains("abc-123"))
  }

  @Test
  func aRemoteCodexEnsureBanksTheRolloutID() throws {
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(
        forNode: goalNode(.codex), at: location))
    let command = try #require(invocation.last)
    #expect(command.contains("notify="))
    #expect(command.contains("thread-id"))
    #expect(command.contains(".graphcode/sessions"))
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

  @Test
  func theLivenessSweepRestartsTheLoopsInsideARunningComposite() async {
    // A codespace restart kills a piloted composite's workers with everything else, and
    // they live on its sub-graph, where a sweep of `graph.nodes` never looked.
    let started = LockIsolated<[UUID]>([])
    let worker = LoopNode(
      title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check")
    let finishedWorker = LoopNode(
      title: "Done", loopType: .goalBased, goal: GoalSpec(summary: "ship"), state: .succeeded)
    let reviewer = LoopNode(title: "Review", loopType: .turnBased, checkDescription: "Sound?")
    let piloted = LoopNode(
      title: "Routine", loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: [worker, finishedWorker, reviewer]),
      pilotState: .piloted)
    let draftWorker = LoopNode(
      title: "Draft worker", loopType: .timeBased, triggerPrompt: "/loop 1h Draft")
    let draft = LoopNode(
      title: "Draft", loopType: .composite,
      subGraph: LoopGraph(project: ProjectRef(path: "draft", name: "draft"), nodes: [draftWorker]))
    let store = GraphStore(
      graph: LoopGraph(
        scope: LoopGraphScope(projectPath: location.projectPath, name: "widget"),
        nodes: [piloted, draft]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node.id) } })

    await store.ensureUnattendedSessionsAlive()

    #expect(started.value == [worker.id])
  }
}

/// A finished unattended loop across a remote reboot: its session comes back as the
/// conversation it was, never as another pass at the task.
@Suite
struct RemoteRebootRestoreTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "codespace", port: 2222, remotePath: "/workspaces/widget")

  private func goalNode() -> LoopNode {
    LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      state: .running)
  }

  @Test
  func theSweepRestoresFinishedLoopsTheRebootKilledAndLeavesThemFinished() async {
    // A finished unattended loop whose pane was still open dialed "waiting for graphcoded"
    // forever after a codespace restart: the pane leaves every unattended loop to the
    // daemon, and the sweep skipped every resolved one.
    let started = LockIsolated<[LoopNode]>([])
    let restored = LockIsolated<[LoopNode]>([])
    let succeeded = LoopNode(
      title: "Done", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      state: .succeeded)
    let stopped = LoopNode(
      title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check", state: .stopped)
    var missingCLI = LoopNode(
      title: "NoCLI", loopType: .goalBased, goal: GoalSpec(summary: "ship"), state: .stopped)
    missingCLI.launchFailure = LaunchFailure(executable: "claude", backend: .claudeCode)
    let turn = LoopNode(
      title: "Read", loopType: .turnBased, checkDescription: "Sound?", state: .succeeded)
    let running = goalNode()
    let store = GraphStore(
      graph: LoopGraph(
        scope: LoopGraphScope(projectPath: location.projectPath, name: "widget"),
        nodes: [succeeded, stopped, missingCLI, turn, running]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } },
      onRestoreRebootedSessions: { nodes, _ in restored.withValue { $0 += nodes } })

    await store.ensureUnattendedSessionsAlive()
    try? await Task.sleep(for: .milliseconds(200))

    #expect(started.value.map(\.id) == [running.id])
    #expect(Set(restored.value.map(\.id)) == [succeeded.id, stopped.id])
    for copy in restored.value {
      let prompt = copy.sessionPrompt(forProjectPath: location.projectPath) ?? ""
      #expect(!prompt.contains("tests pass"))
      #expect(!prompt.contains("/loop"))
    }
    let states = await store.graph.nodes.map(\.state)
    #expect(states == [.succeeded, .stopped, .stopped, .succeeded, .running])
  }

  @Test
  func theRestoreOnlyRunsWhenTheBootChangedAndResumesQuietly() throws {
    let node = LoopNode(
      title: "Done", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      state: .succeeded)
    let quiet = GraphStore.rebootRestoreCopy(of: node)
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(
        forNode: quiet, at: location, onlyAfterReboot: true))
    let script = try #require(invocation.last)
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    #expect(script.contains(RemoteBootMarker.captureFragment))
    #expect(script.contains("cat \(RemoteBootMarker.markerExpression(forSessionName: name))"))
    #expect(script.contains("[ \"$gc_boot\" != \"$gc_last\" ]"))
    #expect(script.contains("'--resume'"))
    #expect(!script.contains("tests pass"))
    let gate = try #require(script.range(of: "[ \"$gc_boot\" != \"$gc_last\" ]"))
    let run = try #require(script.range(of: "'run'"))
    #expect(gate.lowerBound < run.lowerBound)
  }

  @Test
  func everyDaemonEnsureRecordsTheBootItSawTheSessionIn() throws {
    // The marker is what tells a pane, and now the sweep, that a missing session died
    // with the machine. Only a pane attach wrote it, so a session the daemon started and
    // no pane ever joined had no marker, and one the daemon restored kept a stale one.
    let node = goalNode()
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let script = try #require(invocation.last)
    // Quote-free, so the login shell's re-quoting of the script cannot hide it.
    let write = ">\(RemoteBootMarker.markerExpression(forSessionName: name))"
    #expect(script.components(separatedBy: write).count == 3)
  }

  @Test
  func aDaemonKillForgetsTheBootSoTheSessionIsNotRestored() throws {
    // Ended on purpose (a finished loop freed, a stop, a delete): after a later reboot
    // the sweep must not bring it back, and a pane must read "ended", not "rebooted".
    let node = goalNode()
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let script = try #require(
      ZmxSessionLauncher.remoteKillInvocation(forNode: node, at: location).last)
    #expect(script.contains("rm -f \(RemoteBootMarker.markerExpression(forSessionName: name))"))
  }

  @Test
  func theRebootProbeNamesOnlyMissingSessionsFromAnEarlierBoot() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("reboot-probe-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let bin = home.appendingPathComponent("bin", isDirectory: true)
    let boots = home.appendingPathComponent(".graphcode/boots", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: boots, withIntermediateDirectories: true)
    let zmx = bin.appendingPathComponent("zmx")
    let listing =
      "  name=alive\\tpid=1\\tclients=0\\n  name=husk\\tpid=2\\tended=5\\texit_code=0\\n"
    try "#!/bin/sh\nprintf '\(listing)'\n".write(to: zmx, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zmx.path)
    let bootProbe = Process()
    bootProbe.executableURL = URL(fileURLWithPath: "/bin/sh")
    bootProbe.arguments = ["-c", RemoteBootMarker.captureFragment + "; printf %s \"$gc_boot\""]
    let bootPipe = Pipe()
    bootProbe.standardOutput = bootPipe
    try bootProbe.run()
    bootProbe.waitUntilExit()
    let boot = String(decoding: bootPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(!boot.isEmpty)
    for (name, marker) in [
      ("rebooted", "an-earlier-boot"), ("sameboot", boot), ("alive", "an-earlier-boot"),
      ("husk", "an-earlier-boot"),
    ] {
      try marker.write(
        to: boots.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      ZmxSessionLauncher.rebootProbeScript(
        forSessionNames: ["rebooted", "sameboot", "alive", "husk", "unmarked"]),
    ]
    process.environment = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 0)
    #expect(ZmxSessionLauncher.parseRebootProbe(output) == ["rebooted", "husk"])
  }

  @Test
  func aHealthyCodespaceIsNeverProbed() async throws {
    // The probe is a dial, and on a codespace a dial spends the human's API quota. Only
    // a pane redialing its host is worth one; a host nobody is redialing costs nothing.
    let codespace = RemoteProjectLocation(
      host: "fluffy-space-waddle", remotePath: "/workspaces/widget", isCodespace: true)
    let stamp = FileManager.default.temporaryDirectory
      .appendingPathComponent("redial-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: stamp) }
    let gate = ZmxSessionLauncher.RebootProbeGate(stampFor: { _ in stamp })

    #expect(await !gate.panesRedialed(codespace))

    FileManager.default.createFile(atPath: stamp.path, contents: nil)
    #expect(await gate.panesRedialed(codespace))

    await gate.probed(codespace, at: Date().addingTimeInterval(1))
    #expect(await !gate.panesRedialed(codespace))

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: stamp.path)
    #expect(await gate.panesRedialed(codespace))
  }

  @Test
  func aPlainSSHHostIsProbedOnEverySweepWithNoPaneOpen() async {
    // Its dials ride the host's ControlMaster and spend no quota, so finished loops on a
    // rebooted ssh host come back without waiting for a pane to redial.
    let stamp = FileManager.default.temporaryDirectory
      .appendingPathComponent("redial-\(UUID().uuidString)")
    let gate = ZmxSessionLauncher.RebootProbeGate(stampFor: { _ in stamp })

    #expect(await gate.panesRedialed(location))
    await gate.probed(location, at: Date().addingTimeInterval(1))
    #expect(await gate.panesRedialed(location))
  }

  @Test
  func plainSSHHostsAreSweptEveryThirtySecondsAndCodespacesEveryMinute() {
    let codespace = RemoteProjectLocation(
      host: "fluffy-space-waddle", remotePath: "/workspaces/widget", isCodespace: true)

    #expect(ProjectRegistry.remoteLivenessSweepInterval == .seconds(30))
    #expect(
      (1...4).map { ProjectRegistry.sweeps(location, onTick: $0) } == [true, true, true, true])
    #expect(
      (1...4).map { ProjectRegistry.sweeps(codespace, onTick: $0) } == [false, true, false, true])
  }

  @Test(arguments: [false, true])
  func aPaneStampsItsHostBeforeEveryRedial(codespace: Bool) throws {
    let script =
      codespace
      ? SSHReconnectLoop.codespaceScript(
        connect: "CONNECT", reconnect: "RECONNECT", pauseMarker: "/tmp/p",
        redialStamp: "/tmp/stamp")
      : SSHReconnectLoop.script(
        connect: "CONNECT", reconnect: "RECONNECT", redialStamp: "/tmp/stamp")
    let touch = try #require(script.range(of: "touch '/tmp/stamp' 2>/dev/null; RECONNECT"))
    let connect = try #require(script.range(of: "CONNECT"))
    #expect(connect.upperBound <= touch.lowerBound)
  }
}
