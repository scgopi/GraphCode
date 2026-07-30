import Foundation
import Testing

@testable import GraphcodeKit

/// The daemon's half of SSH remote repositories: the argv it builds to start and probe
/// sessions on the remote host, and the local-only guards around briefing and
/// workspace paths. App-side attach and the add form live in `RemoteRepositoryTests`.
@Suite
struct RemoteSessionLaunchTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")

  @Test
  func aRemoteLaunchRunsZmxOnTheRemoteHostInTheRepository() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let invocation = try #require(
      ZmxSessionLauncher.remoteLaunchInvocation(forNode: node, at: location))

    #expect(invocation.first == "/usr/bin/ssh")
    let remoteCommand = try #require(invocation.last)
    // Login shell for the remote PATH, cd into the repository, zmx run detached under
    // the same session name the app attaches to. The whole script is single-quote
    // wrapped by the login-shell layer, so assertions here are on content, not on
    // exact escaping — `hostileTextSurvivesShellQuoting` pins the escaping itself.
    #expect(remoteCommand.hasPrefix("exec zsh -l -i -c '"))
    #expect(remoteCommand.contains("cd "))
    #expect(remoteCommand.contains("/home/dev/widget"))
    #expect(remoteCommand.contains("zmx"))
    #expect(remoteCommand.contains("run"))
    #expect(
      remoteCommand.contains(SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName))
    #expect(remoteCommand.contains("tests pass"))
  }

  @Test
  func aRemoteExistenceCheckAsksTheRemoteZmx() {
    let node = LoopNode(title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "g"))
    let invocation = ZmxSessionLauncher.remoteExistenceInvocation(forNode: node, at: location)
    #expect(invocation.first == "/usr/bin/ssh")
    #expect(invocation.last?.contains("'get'") == true)
  }

  @Test
  func aRemoteSessionGetsNoLocalBriefing() {
    // The briefing file is written on this machine and describes a CLI that talks to
    // this machine's daemon; a remote session can use neither. Stated v1 limitation.
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let arguments = ZmxSessionLauncher.arguments(
      forNode: node, projectPath: location.projectPath)
    #expect(arguments?.contains { $0.contains("--append-system-prompt-file") } == false)
  }

  @Test
  func workspacePathsForARemoteProjectAreRemotePaths() {
    let node = LoopNode(title: "Fix", loopType: .turnBased)
    let paths = ZmxSessionLauncher.workspacePaths(
      forNode: node, projectPath: location.projectPath)
    // The path a path-verifying backend needs is the one the session sees on its host.
    #expect(paths == ["/home/dev/widget"])
  }
}
