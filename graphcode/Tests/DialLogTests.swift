import Foundation
import Testing

@testable import GraphcodeKit
@testable import graphcode

/// The dial log: one bounded line per launch decision, on the machine that made it, so
/// the next "my loop restarted from scratch" report is a diagnosis, not a forensic
/// reconstruction.
@Suite
struct DialLogTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")

  private func agentSurface(loopType: LoopType = .turnBased) -> GhosttyTerminalView {
    let nodeID = UUID()
    return GhosttyTerminalView(
      surfaceID: nodeID,
      sessionName: SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName,
      launchesClaudeCode: true, loopType: loopType,
      initialPrompt: "fix the build", workingDirectory: location.projectPath,
      projectPath: location.projectPath, onProcessExited: { _ in })
  }

  @Test
  func theFragmentIsBoundedAndCanNeverFailItsDial() {
    let fragment = DialLog.fragment(session: "graphcode-x", dial: "connect", event: "attach-live")
    #expect(fragment.contains("dials.log"))
    #expect(fragment.contains("graphcode-x connect attach-live"))
    // Trimmed past the cap before every append, so a night of redials can't eat a disk.
    #expect(fragment.contains("-gt \(DialLog.maxBytes)"))
    #expect(fragment.contains("tail -n \(DialLog.keptLines)"))
    // A full disk or read-only home must never break the launch the log rides on.
    #expect(fragment.hasSuffix("|| true"))
    #expect(fragment.contains("2>/dev/null"))
  }

  @Test
  func recordAppendsAndTrimsPastTheCap() throws {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("dial-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    DialLog.record(session: "graphcode-y", dial: "ensure", event: "fresh", home: home)
    let log = home.appendingPathComponent(".graphcode/dials.log")
    let first = try String(contentsOf: log, encoding: .utf8)
    #expect(first.contains("graphcode-y ensure fresh"))

    let filler = String(repeating: "old line\n", count: 1)
    try String(repeating: filler, count: DialLog.maxBytes / 8).write(
      to: log, atomically: true, encoding: .utf8)
    DialLog.record(session: "graphcode-y", dial: "ensure", event: "resume", home: home)
    let trimmed = try String(contentsOf: log, encoding: .utf8)
    #expect(trimmed.count < DialLog.maxBytes)
    #expect(trimmed.contains("graphcode-y ensure resume"))
  }

  @Test
  func everyRemoteDialBranchAnnouncesItself() throws {
    let view = agentSurface()
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let splitAt = try #require(script.range(of: "while :; do"))
    let connectLine = script[..<splitAt.lowerBound]
    let loopBody = script[splitAt.upperBound...]
    #expect(connectLine.contains("connect attach-live"))
    #expect(connectLine.contains("connect resume"))
    #expect(connectLine.contains("connect fresh"))
    #expect(loopBody.contains("reconnect attach-live"))
    #expect(loopBody.contains("reboot resume"))
    #expect(loopBody.contains("reboot fresh"))
    #expect(loopBody.contains("reconnect session-ended"))
  }

  @Test
  func anUnattendedDialLogsTheWaitInsteadOfAnyLaunch() throws {
    let view = agentSurface(loopType: .goalBased)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(script.contains("connect wait-daemon"))
    #expect(script.contains("reboot wait-daemon"))
    #expect(!script.contains("connect fresh"))
    #expect(!script.contains("connect resume"))
  }

  @Test
  func theEnsureLogsOnlyWhenItActuallyLaunches() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"),
      state: .running)
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("ensure resume"))
    #expect(remoteCommand.contains("ensure fresh"))
    // Both live behind the existence check: a healthy sweep tick logs nothing.
    let check = try #require(remoteCommand.range(of: "'get'"))
    let resume = try #require(remoteCommand.range(of: "ensure resume"))
    #expect(check.upperBound <= resume.lowerBound)
  }

  @Test
  func theLocalOpenLogsItsChoice() throws {
    let nodeID = UUID()
    let name = SurfaceRef(id: nodeID, launchesClaudeCode: true).zmxSessionName
    SessionIDStore.save("abc-123", forNodeID: nodeID)
    defer { SessionIDStore.remove(forNodeID: nodeID) }
    let view = GhosttyTerminalView(
      surfaceID: nodeID, sessionName: name, launchesClaudeCode: true,
      initialPrompt: nil, workingDirectory: "/tmp", projectPath: "/tmp",
      onProcessExited: { _ in })
    let script = try #require(
      view.localResumeOrFreshCommand(agentLaunch: ["claude"])?.last)
    #expect(script.contains("open attach-live"))
    #expect(script.contains("open resume"))
    #expect(script.contains("open resume-dead"))
    #expect(script.contains("open fresh"))
  }
}
