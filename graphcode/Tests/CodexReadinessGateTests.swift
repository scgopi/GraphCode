import Foundation
import Testing

@testable import GraphcodeKit

/// The gate that decides a Codex session is ready to attach, exercised against a **real**
/// `zmx` session created the way graphcode creates every loop's: `zmx run -d`.
///
/// Issue #272 is why this suite runs a real session instead of asserting a pattern. The
/// old gate looked for the agent's name in the session's `cmd=` field, and every test of
/// it checked only that the string was *built* — so nobody noticed that a `zmx run`
/// session has no `cmd=` field at all (zmx records a command for `attach` and hardcodes
/// `.command = null` for `run`, and `zmx ls` prints the field only when it is non-nil).
/// A synthetic, attach-shaped `ls` line would pass happily while every Codex pane in the
/// product spun out its sixty seconds and gave up.
///
/// Commands go through `PTYProcessSession` for the same reason the daemon's own ensure
/// does: `zmx` wants a terminal to create a session against.
@Suite(.serialized)
struct CodexReadinessGateTests {
  private static let zmx = ZmxLocator.binaryURL.path

  private static func quoted(_ value: String) -> String {
    RemoteProjectLocation.shellQuoted(value)
  }

  @discardableResult
  private func run(_ command: String) async -> (succeeded: Bool, output: String) {
    guard
      let session = try? PTYProcessSession(
        executable: "/bin/zsh", arguments: ["-c", command], workingDirectory: nil)
    else { return (false, "") }
    return await session.waitCollectingOutput()
  }

  /// A live session of the exact shape graphcode launches, named after a real node so the
  /// production stamp — which derives the session name from the node — addresses it.
  private func start(_ node: LoopNode) async -> String? {
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    await run(
      "\(Self.quoted(Self.zmx)) run \(Self.quoted(name)) -d /bin/zsh -c 'sleep 30'")
    for _ in 0..<40 {
      if await run(listing(name)).succeeded { return name }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return nil
  }

  private func listing(_ name: String) -> String {
    "\(Self.quoted(Self.zmx)) ls 2>/dev/null | grep -q $'name=\(name)\\t'"
  }

  private func kill(_ name: String) async {
    await run("\(Self.quoted(Self.zmx)) kill \(Self.quoted(name)) >/dev/null 2>&1")
  }

  private func codexNode() -> LoopNode {
    LoopNode(title: "Codex", loopType: .goalBased, goal: GoalSpec(summary: "work"), backend: .codex)
  }

  @Test
  func aRunCreatedSessionNeverCarriesTheCommandTheOldGateLookedFor() async throws {
    guard ZmxLocator.isInstalled else { return }
    let name = try #require(await start(codexNode()))
    defer { Task { await kill(name) } }

    let row = await run(
      "\(Self.quoted(Self.zmx)) ls 2>/dev/null | grep -F \(Self.quoted("name=\(name)\t"))")
    #expect(row.succeeded)
    // The whole of #272 in one assertion: the field the old gate matched on is absent
    // from a session created the way graphcode creates every one of them.
    #expect(!row.output.contains("cmd="))

    // So the old gate could not pass however long the pane waited for it.
    let legacy =
      "\(Self.quoted(Self.zmx)) ls 2>/dev/null | grep -q $'name=\(name)\\t.*cmd=.*codex'"
    #expect(await !run(legacy).succeeded)
  }

  @Test
  func theGateFailsUntilTheDaemonStampsTheAgentLabel() async throws {
    guard ZmxLocator.isInstalled else { return }
    let node = codexNode()
    let name = try #require(await start(node))
    defer { Task { await kill(name) } }

    // The production gate, run against a real session.
    let gate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: Self.zmx, sessionName: name, agent: CLISessionBackendKind.codex.rawValue)
    #expect(await !run(gate).succeeded)

    // The production stamp, run the way the daemon's ensure runs it.
    await run(try #require(ZmxSessionLauncher.agentLabelCommand(zmxPath: Self.zmx, forNode: node)))
    #expect(await run(gate).succeeded)

    // A session running some *other* agent must still not satisfy a Codex gate — that is
    // the whole point of the clause #228 added, and this keeps it.
    let copilotGate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: Self.zmx, sessionName: name, agent: CLISessionBackendKind.copilotCLI.rawValue)
    #expect(await !run(copilotGate).succeeded)
  }

  @Test
  func aLostStampIsRepairedRatherThanRelaunched() async throws {
    guard ZmxLocator.isInstalled else { return }
    let node = codexNode()
    let name = try #require(await start(node))
    defer { Task { await kill(name) } }

    // A session that is alive and unlabelled — a stamp that failed, or one written by a
    // build that predates stamping. The ensure adopts it instead of running `zmx run`
    // against a live session, which would type the launch command into the agent.
    let gate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: Self.zmx, sessionName: name, agent: CLISessionBackendKind.codex.rawValue)
    #expect(await !run(gate).succeeded)

    let repair = try #require(
      ZmxSessionLauncher.adoptUnlabelledCommand(zmxPath: Self.zmx, forNode: node))
    #expect(await run(repair).succeeded)
    #expect(await run(gate).succeeded)
  }

  @Test
  func aSessionLabelledForAnotherAgentIsNotAdopted() async throws {
    guard ZmxLocator.isInstalled else { return }
    let node = codexNode()
    let name = try #require(await start(node))
    defer { Task { await kill(name) } }

    // Alive, but running something else. Relabelling it would make the gate lie; the
    // ensure has to fall through to its relaunch branch instead, so the adopt must fail.
    await run("\(Self.quoted(Self.zmx)) set \(Self.quoted(name)) agent=copilotCLI")
    let repair = try #require(
      ZmxSessionLauncher.adoptUnlabelledCommand(zmxPath: Self.zmx, forNode: node))
    #expect(await !run(repair).succeeded)

    let gate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: Self.zmx, sessionName: name, agent: CLISessionBackendKind.codex.rawValue)
    #expect(await !run(gate).succeeded)
  }

  @Test
  func theGateMatchesTheWholeLabelAndNotAPrefixOfIt() async throws {
    guard ZmxLocator.isInstalled else { return }
    let node = codexNode()
    let name = try #require(await start(node))
    defer { Task { await kill(name) } }

    // No backend's rawValue is a prefix of another today, so this is a trap for whoever
    // adds the one that is rather than a live bug — which is the moment to pin it.
    await run("\(Self.quoted(Self.zmx)) set \(Self.quoted(name)) agent=codexFoo")
    let gate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: Self.zmx, sessionName: name, agent: CLISessionBackendKind.codex.rawValue)
    #expect(await !run(gate).succeeded)

    // And still matches when the label is the last one on the row, where there is no
    // trailing tab to anchor against.
    await run("\(Self.quoted(Self.zmx)) set \(Self.quoted(name)) agent=codex")
    #expect(await run(gate).succeeded)
  }

  @Test
  func aStampAgainstAMissingSessionFailsAndMustNotFailTheEnsure() async {
    guard ZmxLocator.isInstalled else { return }
    // The hazard the `|| true` exists for: an ensure that exits non-zero is retried, and
    // the retry runs `zmx run` against a session that is by then live — which types the
    // entire launch command into the agent's input, the very thing the ensure's atomic
    // check-or-run exists to prevent.
    guard let stamp = ZmxSessionLauncher.agentLabelCommand(
      zmxPath: Self.zmx, forNode: codexNode())
    else { return }
    #expect(await !run(stamp).succeeded)
    #expect(await run("\(stamp) || true").succeeded)
  }

  @Test
  func nothingIsStampedOrRepairedForABackendTheGateNeverJudges() {
    // Codex only. The gate reads a label for Codex alone (`readinessAgent`), so writing
    // one anywhere else is a change to three backends that had no part in #272 — and the
    // stamp is a shell fragment inside the ensure, which is not a place to spend risk.
    for backend in CLISessionBackendKind.allCases where backend != .codex {
      let node = LoopNode(
        title: "Loop", loopType: .goalBased, goal: GoalSpec(summary: "work"), backend: backend)
      #expect(ZmxSessionLauncher.readinessAgent(forNode: node) == nil)
      #expect(ZmxSessionLauncher.agentLabelCommand(zmxPath: "/usr/local/bin/zmx", forNode: node) == nil)
      #expect(
        ZmxSessionLauncher.adoptUnlabelledCommand(zmxPath: "/usr/local/bin/zmx", forNode: node)
          == nil)
      // And the gate for such a node is the name check alone, exactly as before #272.
      let command = ZmxSessionLauncher.aliveCheckCommand(zmxPath: "/usr/local/bin/zmx", forNode: node)
      #expect(!command.contains("agent="))
    }
  }

  @Test
  func theLabelTheDaemonWritesIsTheOneTheGateReads() {
    // One source for the write and the read. The gate used to take `executableName`
    // while nothing wrote anything, so a backend whose binary is named differently from
    // its case (`claudeCode` → `claude`) could have made the two halves disagree.
    let node = codexNode()
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName
    let stamp = ZmxSessionLauncher.agentLabelCommand(zmxPath: "/usr/local/bin/zmx", forNode: node) ?? ""
    let gate = ZmxSessionLauncher.daemonReadyCheckCommand(
      zmxPath: "/usr/local/bin/zmx", sessionName: name,
      agent: CLISessionBackendKind.codex.rawValue)
    #expect(stamp.contains("agent=codex"))
    #expect(gate.contains("agent=codex"))
  }
}
