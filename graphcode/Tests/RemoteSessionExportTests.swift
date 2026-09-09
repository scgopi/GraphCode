import Foundation
import Testing

@testable import GraphcodeKit

/// What `SessionTransplant.exportRemoteArtifact` asks the host for, and how what comes
/// back becomes an artifact. The local export reads this Mac's home directory, which a
/// remote loop never wrote to — so an ssh:// or codespace:// export carried the graph and
/// memory logs and no sessions (issue #333). The remote fetch has to read the id the
/// host banked itself, find the backend's files by that id where the backend keeps them,
/// and hand back exactly the artifact the local export would have built — the same
/// keys — so `restore` and `restoreRemote` stay untouched.
@Suite
struct RemoteSessionExportTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "buildbox", remotePath: "/srv/widget")

  private func node(
    _ backend: CLISessionBackendKind, worktree: String? = nil
  ) -> LoopNode {
    var node = LoopNode(title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "ship"))
    node.backend = backend
    if let worktree {
      node.worktreeBinding = WorktreeRef(
        id: "wt", repositoryPath: "/srv/widget", worktreePath: worktree, branch: "topic")
    }
    return node
  }

  private func script(_ node: LoopNode) throws -> String {
    try #require(SessionTransplant.remoteExportScript(forNode: node, at: location))
  }

  // MARK: - Script shape per backend

  @Test
  func claudeFetchReadsTheBankedIDThenTheTranscriptByID() throws {
    let node = node(.claudeCode)
    let script = try script(node)

    // The id decides which transcript; the directory is found, not reconstructed — a
    // worktree-bound loop's transcript lives under the worktree's slug.
    #expect(
      script.contains("S=$(cat \(PresenceHooks.remoteSessionIDExpression(forNodeID: node.id))"))
    #expect(script.contains("\"$HOME\"/.claude/projects/*/\"$S\".jsonl"))
    #expect(script.hasSuffix("exec tar -cf - -C \"$(dirname \"$F\")\" \"$S.jsonl\""))
  }

  @Test
  func fetchScriptsStreamNothingAndExitCleanlyWhenNothingIsBanked() throws {
    for backend in [CLISessionBackendKind.claudeCode, .copilotCLI, .codex] {
      let script = try script(node(backend))
      #expect(script.contains("|| exit 0"), "\(backend)")
      // The archive is the whole of stdout: nothing may print before `tar` does.
      #expect(!script.contains("echo"), "\(backend)")
      #expect(!script.contains("printf"), "\(backend)")
      #expect(!script.hasPrefix("exec zsh"), "\(backend)")
    }
  }

  @Test
  func copilotFetchFallsBackToTheDirectoryNamedAfterTheZmxSession() throws {
    let node = node(.copilotCLI)
    let script = try script(node)
    let name = SurfaceRef(id: node.id, launchesClaudeCode: true).zmxSessionName

    // Banked id first, then the same `workspace.yaml` walk the ensure's bank fragment
    // does — Copilot has no hook to bank its own id, so a session may be unbanked.
    let bank = try #require(script.range(of: "cat \"$HOME/.graphcode/sessions\""))
    let walk = try #require(script.range(of: "grep -qx 'name: \(name)'"))
    #expect(bank.lowerBound < walk.lowerBound)
    #expect(script.contains("/.copilot/session-state/$d/workspace.yaml"))
    #expect(script.hasSuffix("exec tar -cf - -C \"$HOME/.copilot/session-state\" \"$S\""))
  }

  @Test
  func codexFetchMatchesTheNewestRolloutForTheLoopsWorkingDirectory() throws {
    let project = try script(node(.codex))
    let bound = try script(node(.codex, worktree: "/srv/widget-wt/topic"))

    // The working directory is the only handle on a Codex rollout, and it is the
    // loop's own worktree when it has one, the project folder on the host otherwise.
    #expect(project.contains("W='/srv/widget';"))
    #expect(bound.contains("W='/srv/widget-wt/topic';"))
    #expect(project.contains("\"$HOME\"/.codex/sessions/*/*/*/rollout-*.jsonl"))
    #expect(project.contains("ls -t"))
    #expect(project.contains("\\\"cwd\\\":\\\"$W\\\""))
    #expect(
      project.hasSuffix("exec tar -cf - -C \"$(dirname \"$F\")\" \"$(basename \"$F\")\""))
  }

  @Test
  func openCodeHasNoRemoteFetch() {
    #expect(SessionTransplant.remoteExportScript(forNode: node(.openCode), at: location) == nil)
  }

  @Test
  func bankPathMatchesWhatTheEnsureConsumes() throws {
    // The reader here and the reader in `remoteCreateScript` must name the same file
    // the remote `SessionStart` hook wrote; drifting apart would not fail loudly —
    // every remote export would just silently carry no sessions, the exact bug this
    // path exists to end. Same shape as the install-side parity test.
    let node = node(.claudeCode)
    let script = try script(node)
    let consumed = PresenceHooks.remoteSessionIDExpression(forNodeID: node.id)
    let read = try #require(script.range(of: "S=$(cat "))
    let end = try #require(
      script.range(of: " 2>/dev/null)", range: read.upperBound..<script.endIndex))
    #expect(String(script[read.upperBound..<end.lowerBound]) == consumed)
  }

  // MARK: - The runner

  @Test
  func pipelineUnpacksTheDialsStdoutStraightIntoTarLocally() {
    let staging = URL(fileURLWithPath: "/tmp/graphcode-export-x")
    let pipeline = SessionTransplant.remoteExportPipeline(
      remoteScript: "exec tar -cf - x", staging: staging, at: location)

    // ssh's argv, single-quoted for `/bin/sh`, with its exit status recorded beside the
    // staging directory — a partial archive arrives with a non-zero status and must not
    // be carried — then the untar. The archive never passes through a PTY or a String.
    #expect(pipeline.contains("{ '/usr/bin/ssh' "))
    #expect(pipeline.contains("'dev@buildbox' '--' 'exec tar -cf - x'; "))
    #expect(pipeline.contains("printf %s \"$?\" > '/tmp/graphcode-export-x.status'; }"))
    #expect(pipeline.contains("} | tar -xf - -C '/tmp/graphcode-export-x'; }"))
    #expect(!pipeline.contains("'-t'"))
    #expect(!pipeline.contains("zsh"))
  }

  @Test
  func pipelineIsBoundedAndKillsItsOwnProcessGroupOnTheDeadline() {
    let pipeline = SessionTransplant.remoteExportPipeline(
      remoteScript: "x", staging: URL(fileURLWithPath: "/tmp/s"), at: location)

    // Ten minutes: a stopped Codespace can take five to its first byte; a silent remote
    // or a wedged ssh master must not hold an export forever. The whole group dies, or
    // ssh and tar would outlive the shell still joined by their pipe.
    #expect(SessionTransplant.remoteExportDeadlineSeconds == 600)
    #expect(pipeline.hasPrefix("set -m; "))
    #expect(pipeline.contains("sleep 600; kill -TERM -- -$gc_p"))
    #expect(pipeline.contains("wait $gc_p; gc_s=$?; kill -TERM -- -$gc_w"))
    #expect(pipeline.hasSuffix("exit $gc_s"))
  }

  @Test
  func codespacePipelineDialsThroughGh() {
    let codespace = RemoteProjectLocation(
      host: "fluffy-space", remotePath: "/workspaces/widget", isCodespace: true)
    let pipeline = SessionTransplant.remoteExportPipeline(
      remoteScript: "exec tar -cf - x", staging: URL(fileURLWithPath: "/tmp/s"), at: codespace)

    #expect(pipeline.contains("'codespace' 'ssh' '-c' 'fluffy-space' '--'"))
    #expect(pipeline.hasSuffix(" | tar -xf - -C '/tmp/s'"))
  }

  // MARK: - Fetched files become the local export's artifact

  @Test
  func claudeArchiveBecomesTheTranscriptArtifact() throws {
    let transcript = Data("{\"type\":\"user\"}\n".utf8)
    let artifact = try #require(
      SessionTransplant.artifact(
        fromFetched: ["aaaa-bbbb.jsonl": transcript], backend: .claudeCode,
        workingDirectory: "/srv/widget"))

    #expect(artifact.backend == .claudeCode)
    #expect(artifact.sessionID == "aaaa-bbbb")
    #expect(artifact.sourceWorkingDirectory == "/srv/widget")
    #expect(artifact.files == ["transcript.jsonl": transcript])
  }

  @Test
  func copilotArchiveIsReKeyedRelativeToItsSessionDirectory() throws {
    let artifact = try #require(
      SessionTransplant.artifact(
        fromFetched: [
          "c0ffee/events.jsonl": Data("e".utf8),
          "c0ffee/workspace.yaml": Data("w".utf8),
          "c0ffee/checkpoints/1.md": Data("c".utf8),
        ], backend: .copilotCLI, workingDirectory: "/srv/widget"))

    #expect(artifact.sessionID == "c0ffee")
    #expect(Set(artifact.files.keys) == ["events.jsonl", "workspace.yaml", "checkpoints/1.md"])
  }

  @Test
  func codexArchiveBecomesTheRolloutArtifact() throws {
    let name = "rollout-2026-09-09T10-00-00-0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b.jsonl"
    let artifact = try #require(
      SessionTransplant.artifact(
        fromFetched: [name: Data("r".utf8)], backend: .codex, workingDirectory: "/srv/widget"))

    #expect(artifact.sessionID == name)
    #expect(artifact.files == ["rollout.jsonl": Data("r".utf8)])
  }

  @Test
  func anythingButOneWholeSessionIsRefused() {
    let empty: [String: Data] = [:]
    #expect(
      SessionTransplant.artifact(fromFetched: empty, backend: .claudeCode, workingDirectory: "/")
        == nil)
    #expect(
      SessionTransplant.artifact(
        fromFetched: ["a.jsonl": Data(), "b.jsonl": Data()], backend: .claudeCode,
        workingDirectory: "/") == nil)
    #expect(
      SessionTransplant.artifact(
        fromFetched: ["one/events.jsonl": Data(), "two/events.jsonl": Data()],
        backend: .copilotCLI, workingDirectory: "/") == nil)
    #expect(
      SessionTransplant.artifact(
        fromFetched: ["x.jsonl": Data()], backend: .openCode, workingDirectory: "/") == nil)
  }

  @Test
  func anUnreachableHostYieldsNoSessionRatherThanAFailure() async {
    // Port 1 on loopback refuses at once, so the dial dies before a byte arrives — the
    // runner must hand back nil, and the bundle builder must carry on without it.
    let unreachable = RemoteProjectLocation(
      user: "nobody", host: "127.0.0.1", port: 1, remotePath: "/srv/none")
    let node = node(.claudeCode)

    let artifact = await SessionTransplant.exportRemoteArtifact(forNode: node, at: unreachable)
    let sessions = await ProjectPersistence.remoteAwareSessionArtifacts(
      for: [node], projectPath: unreachable.projectPath)

    #expect(artifact == nil)
    #expect(sessions.isEmpty)
  }

  // MARK: - The bundle builders

  @Test
  func localProjectsCollectSessionsTheSameWayThroughEitherBuilder() async throws {
    // The async builders exist for remote projects; a local path must take the same
    // disk read the synchronous ones do, or the app and CLI would export local loops
    // differently from before.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("remote-export-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(baseDirectory: directory)
    let project = ProjectRef(path: directory.path, name: "local")
    let graph = LoopGraph(project: project, nodes: [node(.claudeCode)])

    // From a synchronous closure: in an async context the async overload wins, which is
    // the resolution the app and CLI rely on.
    let sync = {
      persistence.createExportBundle(
        for: [graph.nodes[0].id], from: graph, projectPath: project.path)
    }()
    let async = await persistence.createExportBundle(
      for: [graph.nodes[0].id], from: graph, projectPath: project.path)
    let full = await persistence.createFullGraphExportBundle(
      for: graph, projectPath: project.path)

    #expect(sync?.sessionsByNodeID.keys == async?.sessionsByNodeID.keys)
    #expect(sync?.manifest.contents.nodeIDs == async?.manifest.contents.nodeIDs)
    #expect(full.manifest.contents.isFullGraph)
    #expect(full.manifest.contents.nodeIDs == [graph.nodes[0].id.uuidString])
  }
}
