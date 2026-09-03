import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct GoobersWorkspaceTests {
  @Test
  func parsesTheCommonGitHubOriginForms() {
    let origins = [
      "https://github.com/Agent-Clubhouse/Goobers.git",
      "git@github.com:Agent-Clubhouse/Goobers.git",
      "ssh://git@github.com/Agent-Clubhouse/Goobers.git",
    ]
    for origin in origins {
      let parsed = GoobersWorkspace.parseGitHubOrigin(origin)
      #expect(parsed?.owner == "Agent-Clubhouse")
      #expect(parsed?.name == "Goobers")
    }
    #expect(GoobersWorkspace.parseGitHubOrigin("https://example.com/acme/repo") == nil)
  }

  @Test
  func preparesAPersistentInstanceAndAnImmutableSnapshot() throws {
    let base = temporaryDirectory()
    let project = base.appendingPathComponent("repo", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], at: project)
    try git(["config", "user.name", "GraphCode Tests"], at: project)
    try git(["config", "user.email", "graphcode-tests@example.invalid"], at: project)
    try git(["commit", "--allow-empty", "-q", "-m", "base"], at: project)
    try git(
      ["remote", "add", "origin", "https://github.com/example/demo.git"],
      at: project)
    try git(["update-ref", "refs/remotes/origin/main", "HEAD"], at: project)
    try git(
      ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"],
      at: project)
    try git(["switch", "-q", "-c", "local-only"], at: project)

    let first = LoopNode(
      title: "Research", loopType: .turnBased, checkDescription: "Useful?",
      firstInstruction: "Read the README", backend: .copilotCLI)
    let second = LoopNode(
      title: "Report", loopType: .turnBased, checkDescription: "Clear?",
      firstInstruction: "Summarize it", backend: .copilotCLI)
    var graph = LoopGraph(
      project: ProjectRef(path: project.path, name: "Demo Project"),
      nodes: [first, second])
    graph.edges = [LoopEdge(from: first.id, to: second.id, kind: .handoff)]
    graph.goobersTriggers = [
      .schedule("@every 5m"),
      .webhook(events: ["pull_request"]),
    ]
    let workspace = GoobersWorkspace(graphID: graph.id, baseDirectory: base)

    let prepared = try workspace.prepare(graph)

    #expect(prepared.root == workspace.root)
    #expect(prepared.gaggle == "graphcode")
    #expect(prepared.workflow == "demo-project")
    #expect(GoobersWorkspace.runnableBranch(at: project.path) == "main")
    #expect(
      FileManager.default.fileExists(
        atPath: workspace.root.appendingPathComponent("instance.yaml").path))
    #expect(
      try String(
        contentsOf: workspace.root.appendingPathComponent("instance.yaml"),
        encoding: .utf8
      ).contains("webhook:"))
    let secret = workspace.root.appendingPathComponent("secrets/webhook-secret")
    #expect(FileManager.default.fileExists(atPath: secret.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: secret.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(workspace.triggersActive)
    #expect(
      FileManager.default.fileExists(
        atPath:
          workspace.root
          .appendingPathComponent("config/gaggles/graphcode/workflows/demo-project.yaml")
          .path))
    let workflow = try String(
      contentsOf:
        workspace.root
        .appendingPathComponent("config/gaggles/graphcode/workflows/demo-project.yaml"),
      encoding: .utf8)
    #expect(workflow.contains("type: schedule"))
    #expect(workflow.contains("schedule: \"@every 5m\""))
    #expect(workflow.contains("type: webhook"))
    #expect(workflow.contains("- pull_request"))
    #expect(
      FileManager.default.fileExists(
        atPath:
          workspace.root
          .appendingPathComponent("snapshots/\(prepared.snapshotID)/config/manifest.yaml")
          .path))
  }

  @Test
  func deletingAWorkspaceRemovesOnlyThatGraphsDirectory() async throws {
    let base = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let first = GoobersWorkspace(graphID: UUID(), baseDirectory: base)
    let second = GoobersWorkspace(graphID: UUID(), baseDirectory: base)
    try FileManager.default.createDirectory(at: first.root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second.root, withIntermediateDirectories: true)

    try await first.remove()

    #expect(!FileManager.default.fileExists(atPath: first.root.path))
    #expect(FileManager.default.fileExists(atPath: second.root.path))
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-goobers-workspace-\(UUID().uuidString)", isDirectory: true)
  }

  private func git(_ arguments: [String], at directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}
