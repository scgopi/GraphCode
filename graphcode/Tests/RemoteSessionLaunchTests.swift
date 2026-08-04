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
  func aRemoteEnsureChecksAndRunsInOneShell() throws {
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))

    #expect(invocation.first == "/usr/bin/ssh")
    let remoteCommand = try #require(invocation.last)
    // Login shell for the remote PATH, cd into the repository, then the create-only
    // pair: `zmx get || zmx run`, detached, under the same session name the app
    // attaches to. The whole script is single-quote wrapped by the login-shell layer,
    // so assertions here are on content, not exact escaping —
    // `hostileTextSurvivesShellQuoting` pins the escaping itself.
    #expect(remoteCommand.hasPrefix("exec zsh -l -i -c '"))
    #expect(remoteCommand.contains("cd "))
    #expect(remoteCommand.contains("/home/dev/widget"))
    #expect(remoteCommand.contains("'get'"))
    #expect(remoteCommand.contains("||"))
    #expect(remoteCommand.contains("run"))
    #expect(
      remoteCommand.contains(SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName))
    #expect(remoteCommand.contains("tests pass"))

    // The check must come first: run-then-check would defeat the whole point. Two ssh
    // round-trips here was the composer bug — the app's attach created the session in
    // the seconds between them, and the daemon's late `zmx run` typed the entire
    // launch command into the live agent's input bar.
    let get = try #require(remoteCommand.range(of: "'get'"))
    let run = try #require(remoteCommand.range(of: "'run'"))
    #expect(get.lowerBound < run.lowerBound)
  }

  @Test
  func aRemoteCopilotLaunchSeedsFolderTrustFirst() throws {
    // An unattended Copilot queues its --interactive goal behind a per-session
    // folder-trust dialog nobody answers — the goal parked forever on a fresh remote
    // loop. The ensure pre-trusts the one repository the loop was pointed at.
    let node = LoopNode(
      title: "hi", loopType: .goalBased, goal: GoalSpec(summary: "say hi"),
      backend: .copilotCLI)
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    #expect(remoteCommand.contains("trustedFolders"))
    #expect(remoteCommand.contains("python3"))
    #expect(remoteCommand.contains("/home/dev/widget"))
    // Never load-bearing: a failed seed must fall back to today's dialog, not block
    // the launch.
    #expect(remoteCommand.contains("|| true"))
    // And the seed runs before the create-only pair.
    let seed = try #require(remoteCommand.range(of: "trustedFolders"))
    let get = try #require(remoteCommand.range(of: "'get'"))
    #expect(seed.lowerBound < get.lowerBound)
  }

  @Test
  func aRemoteClaudeLaunchIsUntouchedByTrustSeeding() throws {
    // The seed is Copilot-scoped: Claude's remote script must not carry it. (python3
    // itself now appears for every backend — the delivery fragment rides on it.)
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(forNode: node, at: location))
    let remoteCommand = try #require(invocation.last)

    #expect(!remoteCommand.contains("trustedFolders"))
  }

  @Test
  func aRemoteMessageRidesSSHAndSubmitsSeparately() throws {
    // Delivery used to speak only to the local zmx socket, which has never heard of a
    // remote loop's session — every message to one failed and staged. The send now
    // rides ssh, and keeps the local path's paste-heuristic dance: text, a beat, then
    // Enter as its own keystroke, all in one remote shell.
    let node = LoopNode(title: "hi", loopType: .goalBased, goal: GoalSpec(summary: "g"))
    let invocation = ZmxSessionLauncher.remoteSendInvocation(
      "[graphcode] parent: task done", toNode: node, at: location)

    #expect(invocation.first == "/usr/bin/ssh")
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("send"))
    #expect(remoteCommand.contains("task done"))
    #expect(remoteCommand.contains("sleep"))
    #expect(
      remoteCommand.contains(SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName))
  }

  @Test
  func aRemoteKillReachesTheRemoteZmx() throws {
    // Stop and delete route their kill by project path; without this a remote loop's
    // session outlived its node forever — the local zmx had nothing to kill.
    let node = LoopNode(title: "hi", loopType: .goalBased, goal: GoalSpec(summary: "g"))
    let invocation = ZmxSessionLauncher.remoteKillInvocation(forNode: node, at: location)

    #expect(invocation.first == "/usr/bin/ssh")
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("kill"))
    #expect(
      remoteCommand.contains(SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName))
  }

  @Test
  func aRemoteSessionIsBriefedAtItsOwnHostsPaths() throws {
    // The v1 limitation this replaces withheld the briefing entirely: the file was
    // local and the CLI it describes talked to a daemon the remote host couldn't
    // reach. Now the ensure dial delivers both file and CLI, the forwarded socket
    // makes the CLI work, and the argv names the file where the *session* finds it —
    // a `~/`-path its own login shell expands.
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node, projectPath: location.projectPath, settings: GraphcodeSettings()))
    let flag = try #require(arguments.firstIndex(of: "--append-system-prompt-file"))
    #expect(arguments[flag + 1].hasPrefix("~/.graphcode/briefings/"))
    #expect(arguments[flag + 1].hasSuffix("AGENTS.md"))
  }

  @Test
  func aRemoteEnsureDeliversTheCLIAndBriefingBeforeLaunching() throws {
    // The delivery fragment must precede the create-only pair: a `zmx run` that fires
    // has to find every path its argv names already on the host's disk.
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let invocation = try #require(
      ZmxSessionLauncher.remoteEnsureInvocation(
        forNode: node, at: location, settings: GraphcodeSettings()))
    let remoteCommand = try #require(invocation.last)

    #expect(remoteCommand.contains("python3"))
    #expect(remoteCommand.contains("b64decode"))
    // Never load-bearing: a failed delivery degrades to an unbriefed session, not a
    // blocked launch.
    #expect(remoteCommand.contains("|| true"))
    let deliver = try #require(remoteCommand.range(of: "b64decode"))
    let get = try #require(remoteCommand.range(of: "'get'"))
    #expect(deliver.lowerBound < get.lowerBound)
  }

  @Test
  func aRemoteWakeDigestIsPointedAtTheDeliveredCopy() throws {
    // The staged-message black hole: a message to a non-live remote loop lands in its
    // memory log on this machine, and the wake digest is the only thing that carries
    // it back to the session. The prompt must point at the *delivered* copy on the
    // remote host, and the delivery must actually include it.
    let node = LoopNode(
      title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    NodeMemory.append(
      "while you were away: parent says stop", projectPath: location.projectPath,
      nodeID: node.id)
    defer { NodeMemory.remove(projectPath: location.projectPath, nodeID: node.id) }

    let arguments = try #require(
      ZmxSessionLauncher.arguments(
        forNode: node, projectPath: location.projectPath, settings: GraphcodeSettings()))
    let prompt = try #require(arguments.last)
    #expect(prompt.contains("Read your loop memory at ~/.graphcode/memory/"))
    #expect(prompt.contains(node.id.uuidString))

    let delivery = try #require(
      ZmxSessionLauncher.remoteDeliveryScript(
        forNode: node, at: location, settings: GraphcodeSettings()))
    // The digest rides inside the base64 manifest, so its presence is visible only as
    // the manifest growing past the shim+briefing baseline — assert on the manifest
    // naming the node's memory path instead, by decoding what the installer is handed.
    #expect(deliveredPaths(in: delivery).contains { $0.contains(node.id.uuidString) })
  }

  @Test
  func theDeliveryManifestCarriesShimAndBriefingAtCanonicalPaths() throws {
    let delivery = try #require(
      ZmxSessionLauncher.remoteDeliveryScript(
        forNode: nil, at: location, settings: GraphcodeSettings()))
    let paths = deliveredPaths(in: delivery)
    #expect(paths.contains("~/.graphcode/bin/graphcode"))
    #expect(paths.contains { $0.hasPrefix("~/.graphcode/briefings/") })

    // And with briefing switched off, the shim still ships — the CLI is not a
    // briefing feature, it's what `node send`'s report-back route relies on.
    let unbriefed = try #require(
      ZmxSessionLauncher.remoteDeliveryScript(
        forNode: nil, at: location,
        settings: GraphcodeSettings(briefsSessionsAboutTheGraph: false)))
    #expect(deliveredPaths(in: unbriefed) == ["~/.graphcode/bin/graphcode"])
  }

  /// Decodes the installer fragment's base64 JSON manifest back into the delivered
  /// paths — asserting on what actually lands rather than on encoding details.
  private func deliveredPaths(in script: String) -> [String] {
    let tokens = script.split(separator: " ")
    for token in tokens.reversed() {
      let raw = token.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
      guard let data = Data(base64Encoded: raw),
        let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      else { continue }
      return manifest.keys.sorted()
    }
    return []
  }

  @Test
  func onlyGraphcodesOwnPathsRideOutsideTheQuotes() {
    // The remote login shell must expand the tilde on paths graphcode minted — and
    // nothing else: a prompt that happens to start with `~/` is content, not a path.
    let line = ZmxSessionLauncher.remoteQuotedCommand([
      "zmx", "~/.graphcode/briefings/x/AGENTS.md", "~/somewhere else", "plain",
    ])
    #expect(line.contains("~/'.graphcode/briefings/x/AGENTS.md'"))
    #expect(line.contains("'~/somewhere else'"))
    #expect(line.contains("'plain'"))
  }

  @Test
  func theSocketForwardIsPersistentSelfCleaningAndFailsFast() {
    let script = RemoteSocketForwarder.forwardScript(
      for: location, localSocketPath: "/Users/u/.graphcode/graphcoded.sock")
    // `-N`: forward only, no remote command to exit and take the socket with it.
    #expect(script.contains("'-N'"))
    // A stale socket from a crash blocks the bind and sshd offers no client-side
    // unlink — so every attempt removes it first and fails fast rather than holding
    // a useless connection.
    #expect(script.contains("rm -f"))
    #expect(script.contains("ExitOnForwardFailure=yes"))
    // The remote bind path is anchored to the remote home the pre-dial printed;
    // nothing local knows it.
    #expect(script.contains("\"$H\"'/.graphcode/graphcoded.sock:/Users/u/.graphcode/graphcoded.sock'"))
    // Reconnects while its daemon lives, dies with it — an orphan would fight the
    // restarted daemon's forwarder for the bind forever.
    #expect(script.contains("kill -0 $PPID"))
    #expect(script.contains("'-p' '2222'"))
    #expect(script.contains("'dev@build-box'"))
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
