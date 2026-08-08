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
      remoteCommand.contains("$HOME/.graphcode/sessions/\(node.id.uuidString).id"))
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
  func aCodexNodeHasNoResumeToOffer() {
    // Codex has no `--resume` graphcode has spiked, so the remote ensure keeps the
    // single fresh-launch branch rather than inventing a flag.
    #expect(
      ZmxSessionLauncher.resumeArguments(
        forNode: goalNode(.codex), sessionID: "abc-123", projectPath: location.projectPath)
        == nil)
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
