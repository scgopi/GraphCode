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
@Suite
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
    // A live session is still just joined — the same reattach the pane always did.
    #expect(script.contains("'get'"))
    #expect(script.contains("'attach'"))
  }

  @Test
  func aNodeWithNothingBankedStillLaunchesFresh() {
    let nodeID = UUID()
    let view = surface(nodeID: nodeID)
    let command = withBankedID(nil, forNode: nodeID) {
      view.localResumeOrFreshCommand(agentLaunch: ["claude", "the prompt"])
    }
    // Nothing to resume is the first launch, and the ordinary argv is what it gets.
    #expect(command == nil)
  }

  @Test
  func aBackendThatCannotResumeIsUnaffected() {
    let nodeID = UUID()
    let view = surface(nodeID: nodeID, backend: .codex)
    let command = withBankedID("abc-123", forNode: nodeID) {
      view.localResumeOrFreshCommand(agentLaunch: ["codex", "the prompt"])
    }
    #expect(command == nil)
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
