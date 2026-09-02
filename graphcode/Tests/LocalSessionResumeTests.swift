import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// A *local* machine rebooting, and the asymmetry that cost a real conversation.
///
/// The daemon could always resume: `ensureUnattendedSessions` reads `SessionIDStore` and
/// passes `--resume`. Opening a loop could not — `GhosttyTerminalView` built one argv,
/// `zmx attach <name> <agent> <prompt>`, so a pane that found the session gone started
/// the agent over from its goal. That is not a corner case: an app update replaces the
/// `zmx` binary and reloads the daemon, every session dies with the old server, and
/// locally there is no liveness sweep to bring them back. Opening the loops afterwards
/// rebanked their IDs (the `SessionStart` hook writes the pointer) over the ones holding
/// days of work, leaving those transcripts on disk with nothing naming them — and every
/// reboot afterwards resumed the near-empty replacements. Observed 2026-08-11 on three
/// loops at once.
@Suite(.serialized)
struct LocalSessionResumeTests {
  private let projectPath = "/tmp/widget"

  private func surface(
    nodeID: UUID = UUID(), backend: CLISessionBackendKind = .claudeCode
  ) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: nodeID,
      sessionName: SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, backend: backend, loopType: .goalBased,
      initialPrompt: "Work toward this goal until it is met: ship it",
      workingDirectory: projectPath, projectPath: projectPath, onProcessExited: { _ in })
  }

  /// The banked ID is real state on this disk, so these tests write one and clean up.
  private func withBankedID<T>(
    _ sessionID: String?, forNode nodeID: UUID, _ body: () throws -> T
  ) rethrows -> T {
    if let sessionID {
      SessionIDStore.save(sessionID, forNodeID: nodeID)
    } else {
      SessionIDStore.remove(forNodeID: nodeID)
    }
    defer { SessionIDStore.remove(forNodeID: nodeID) }
    return try body()
  }

  // MARK: - The pane resumes rather than re-prompting

  @Test
  func openingALoopWithABankedIDResumesInsteadOfReplayingTheGoal() throws {
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let script = try withBankedID("abc-123", forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])?.last)
    }
    #expect(script.contains(#"--resume "$GRAPHCODE_RESUME_ID""#))
    #expect(script.contains(SessionIDStore.file(forNodeID: nodeID).path))
    // A live session is still just joined — the same reattach the pane always did, now
    // behind the daemon's husk-aware listing check rather than a bare `zmx get`.
    #expect(script.contains("ls 2>/dev/null"))
    #expect(script.contains("'attach'"))
  }

  @Test
  func aNodeWithNothingBankedStillLaunchesFreshAndSaysSo() throws {
    // The fresh launch used to be a bare argv with no log line — the one silent branch,
    // and the one a user's `dials.log` could never explain. The decision is made by the
    // script at run time from what is banked *then*, so the shape is the same either way.
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let script = try withBankedID(nil, forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])?.last)
    }
    #expect(script.contains("open fresh"))
    #expect(script.contains("the prompt"))
    #expect(script.contains(SessionIDStore.file(forNodeID: nodeID).path))
  }

  @Test
  func aDeadShellLeftByTheAgentIsKilledBeforeTheRelaunch() throws {
    // An agent that died inside its session leaves the shell at a prompt, which answers
    // `zmx get` for as long as the machine stays up. The old check joined that corpse;
    // the daemon's husk-aware check (`ended=`) falls through, and the husk is killed so
    // the resume-or-fresh verdict below it stays measurable.
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let script = try withBankedID("abc-123", forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])?.last)
    }
    #expect(script.contains("ended="))
    #expect(script.contains("open husk-killed"))
    let kill = try #require(script.range(of: "'kill'"))
    let resume = try #require(script.range(of: "open resume"))
    #expect(kill.upperBound < resume.lowerBound)
    // The kill keys off positive evidence — a listing row carrying `ended=` — not off
    // the liveness check failing: that also fails on an `err=` row, which is a busy
    // daemon missing its probe, and killing on it would take a live agent down.
    let ended = try #require(script.range(of: #"grep -q $'\tended='"#))
    #expect(ended.upperBound < kill.lowerBound)
    #expect(!script.contains("'get'"))
    // zsh, so the alive check's `$'\t'` is read as a tab wherever `/bin/sh` points.
    #expect(view.localResumeOrFreshCommand(agentLaunch: ["claude"])?.first == "/bin/zsh")
  }

  // MARK: - Copilot, which cannot bank its own ID

  @Test
  func aCopilotLoopWithNothingBankedResumesFromItsSessionDirectory() throws {
    // Copilot has no hook; on a remote host the daemon banks its directory name, locally
    // nobody did. Opening such a loop with its session gone relaunched `copilot --name
    // graphcode-<id>` from the goal: a second Copilot session for one loop, every reboot,
    // unlogged. The pane now discovers and banks the same ID the daemon would.
    let nodeID = UUID()
    let name = SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try copilotSession(named: name, in: root)
    CopilotSessionLog.stateDirectory = root
    defer {
      CopilotSessionLog.stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }
    let view = surface(nodeID: nodeID, backend: .copilotCLI)
    let script = try withBankedID(nil, forNode: nodeID) {
      let script = try #require(
        view.localResumeOrFreshCommand(agentLaunch: ["copilot", "the prompt"])?.last)
      #expect(SessionIDStore.load(forNodeID: nodeID) == directory.lastPathComponent)
      #expect(
        SessionIDStore.history(forNodeID: nodeID).last?.sessionID == directory.lastPathComponent)
      return script
    }
    defer { try? FileManager.default.removeItem(at: SessionIDStore.historyFile(forNodeID: nodeID)) }
    #expect(script.contains(#"--resume "$GRAPHCODE_RESUME_ID""#))
  }

  @Test
  func theNewestDirectoryWithTheNameWinsAndTheBankIsIdempotent() throws {
    // A loop that already has a duplicate must resume the one being written to now, and
    // an ensure tick that finds the same ID banked must not grow the history.
    let nodeID = UUID()
    let name = SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = try copilotSession(named: name, in: root)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older.path)
    let newer = try copilotSession(named: name, in: root)
    CopilotSessionLog.stateDirectory = root
    defer {
      CopilotSessionLog.stateDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state", isDirectory: true)
    }
    defer {
      SessionIDStore.remove(forNodeID: nodeID)
      try? FileManager.default.removeItem(at: SessionIDStore.historyFile(forNodeID: nodeID))
    }
    let discovered = ZmxSessionLauncher.resumableSessionID(forNodeID: nodeID, backend: .copilotCLI)
    #expect(discovered == newer.lastPathComponent)
    ZmxSessionLauncher.bankCopilotSessionID(
      newer.lastPathComponent, forNodeID: nodeID, workingDirectory: projectPath)
    ZmxSessionLauncher.bankCopilotSessionID(
      newer.lastPathComponent, forNodeID: nodeID, workingDirectory: projectPath)
    #expect(SessionIDStore.history(forNodeID: nodeID).count == 1)
    #expect(SessionIDStore.history(forNodeID: nodeID).first?.workingDirectory == projectPath)
    // Once banked, the pointer is the answer — for a Claude node there is no directory
    // to fall back to at all.
    #expect(
      ZmxSessionLauncher.resumableSessionID(forNodeID: nodeID, backend: .claudeCode)
        == newer.lastPathComponent)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("copilot-resume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func copilotSession(named name: String, in root: URL) throws -> URL {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "client_name: github/cli\nname: \(name)\n".write(
      to: directory.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
    return directory
  }

  @Test
  func codexResumesFromItsSessionID() throws {
    let nodeID = UUID()
    let view = surface(nodeID: nodeID, backend: .codex)
    let command = try withBankedID("abc-123", forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["codex", "the prompt"])?.last)
    }
    #expect(command.contains("resume"))
    #expect(command.contains(#""$GRAPHCODE_RESUME_ID""#))
    #expect(command.contains("the prompt"))
    let resume = try #require(command.range(of: "resume"))
    let fallback = try #require(command.range(of: "the prompt"))
    #expect(resume.upperBound < fallback.lowerBound)
  }

  // MARK: - A resume that does not take

  @Test
  func aDeadIDFallsThroughToAFreshLaunchRatherThanClosingThePane() throws {
    // `claude --resume` against a transcript its retention expired dies at once, and
    // `zmx attach` hands that exit straight to the pane, which reads as the loop having
    // finished. Only this script can see how long the session lived, so it measures.
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let script = try withBankedID("dead-id", forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])?.last)
    }
    #expect(script.contains("gc_t0=$(date +%s)"))
    #expect(script.contains("-ge \(ZmxSessionLauncher.resumeSettleSeconds)"))
    #expect(script.contains("Resume did not take"))
    // The fresh launch is what follows, prompt and all.
    let verdict = try #require(script.range(of: "Resume did not take"))
    #expect(script[verdict.upperBound...].contains("the prompt"))
  }

  @Test
  func theIDIsDroppedOnlyAfterAResumeIsSeenToFail() throws {
    // Not consumed up front, unlike the remote path: there one restorer owns the loop,
    // here the daemon's ensure may be running the same resume concurrently, and two
    // consumers racing on one `rm` is how the loser falls through to a fresh launch —
    // the very failure this exists to end.
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let script = try withBankedID("abc-123", forNode: nodeID) {
      try #require(view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])?.last)
    }
    let removal = try #require(script.range(of: "rm -f"))
    let attempt = try #require(script.range(of: #"--resume "$GRAPHCODE_RESUME_ID""#))
    #expect(attempt.upperBound < removal.lowerBound)
  }

  @Test
  func aResumedLocalSessionStillReportsItsPresence() throws {
    // Without the hooks a resumed loop reads IDLE for as long as it runs — the fresh
    // launch has always passed them, and a resume that dropped them would make every
    // post-reboot card lie.
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let resume = try #require(
      view.resumeCommand(
        settings: GraphcodeSettings(), hooksFile: URL(fileURLWithPath: "/tmp/hooks.json"),
        remoteSettingsPath: nil)
    ).joined(separator: " ")
    #expect(resume.contains("--settings"))
    #expect(resume.contains("/tmp/hooks.json"))
    // No opening prompt: a resumed conversation already had one.
    #expect(!resume.contains("GRAPHCODE_TRIGGER_PROMPT"))
  }

  // MARK: - The history beside the pointer

  @Test
  func everyBankedIDIsAppendedToAHistoryBesideThePointer() throws {
    // The pointer is last-writer-wins by design; the history is what made the 2026-08-11
    // recovery possible at all, and it was pure forensics — transcript sizes and birth
    // times out of `~/.claude/projects`.
    let json = try #require(
      PresenceHooks.json(forBackend: .claudeCode, zmxPath: "/opt/zmx"))
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    let hooks = try #require(parsed["hooks"] as? [String: Any])
    let matchers = try #require(hooks["SessionStart"] as? [[String: Any]])
    let entries = try #require(matchers.first?["hooks"] as? [[String: Any]])
    let capture = try #require(
      entries.compactMap { $0["command"] as? String }
        .first { $0.contains("CLAUDE_CODE_SESSION_ID") })

    #expect(capture.contains(".history"))
    #expect(capture.contains("$PWD"))
    // Appended, never rewritten — and written before the pointer, so no ID the pointer
    // names is ever missing from the history.
    #expect(capture.contains(">>"))
    let history = try #require(capture.range(of: ".history"))
    let pointer = try #require(capture.range(of: ".id"))
    #expect(history.upperBound < pointer.lowerBound)
  }

  @Test
  func theHistoryReadsBackTheIDsAndWhereTheyRan() throws {
    let nodeID = UUID()
    let file = SessionIDStore.historyFile(forNodeID: nodeID)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "1786498552 aaa /Volumes/SCG/wd/widget\n1786499999 bbb /tmp/wt\n"
      .write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }

    let history = SessionIDStore.history(forNodeID: nodeID)
    #expect(history.map(\.sessionID) == ["aaa", "bbb"])
    #expect(history.last?.workingDirectory == "/tmp/wt")
  }
}
