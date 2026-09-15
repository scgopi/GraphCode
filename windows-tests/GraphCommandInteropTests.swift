import Foundation
import XCTest
import IdentifiedCollections

@testable import GraphcodeKit

final class GraphCommandInteropTests: XCTestCase {
  func testCreateEdgeWirePayloadDecodesToSwiftGraphCommand() throws {
    let data = try fixture("daemon-v2-create-edge.json")
    let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: data)
    XCTAssertEqual(
      envelope.command,
      .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .createEdge(
          from: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
          to: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
          spec: EdgeSpec())))
  }

  func testDeleteEdgeWirePayloadDecodesToSwiftGraphCommand() throws {
    let data = try fixture("daemon-v2-delete-edge.json")
    let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: data)
    XCTAssertEqual(
      envelope.command,
      .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .deleteEdge(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)))
  }

  func testLifecycleAndExtendedGraphFixturesDecodeToSwiftCommands() throws {
    let node = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let child = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let cases: [(String, DaemonCommand)] = [
      ("daemon-v2-close-project.json", .closeProject(path: "C:\\work\\graph")),
      ("daemon-v2-forget-project.json", .forgetProject(path: "C:\\work\\graph")),
      ("daemon-v2-delete-project-graph.json", .deleteProjectGraph(path: "C:\\work\\graph")),
      ("daemon-v2-delete-node.json", .graphCommand(projectPath: "C:\\work\\graph", command: .deleteNode(node))),
      ("daemon-v2-update-node.json", .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .updateNode(node, update: NodeUpdate(
          goalSummary: "Done", goalPredicate: "test -f done", pollIntervalSeconds: 30,
          modelTier: .fast)))),
      ("daemon-v2-memo-node.json", .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .memoNode(node, text: "learned", from: nil))),
      ("daemon-v2-refresh-usage.json", .graphCommand(
        projectPath: "C:\\work\\graph", command: .refreshUsage)),
      ("daemon-v2-arm-composite.json", .graphCommand(
        projectPath: "C:\\work\\graph", command: .armComposite(node))),
      ("daemon-v2-pilot-arm-refresh.json", .graphCommand(
        projectPath: "C:\\work\\graph", command: .pilotComposite(node))),
      ("daemon-v2-subgraph-command.json", .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .subGraphCommand(nodeID: node, command: .deleteNode(child)))),
    ]
    for (name, expected) in cases {
      let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: fixture(name))
      XCTAssertEqual(envelope.command, expected, name)
    }
  }

  func testNodeDraftAndLoopGraphFixturesDecodeWithCompleteSwiftSchema() throws {
    let draft = try JSONDecoder().decode(NodeDraft.self, from: fixture("swift-node-draft-valid.json"))
    XCTAssertEqual(draft.id, UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
    XCTAssertNil(draft.backend)
    XCTAssertEqual(draft.firstInstruction, "work")

    let graph = try JSONDecoder().decode(LoopGraph.self, from: fixture("swift-loopgraph-valid.json"))
    XCTAssertEqual(graph.id, UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
    XCTAssertEqual(graph.project.path, "C:\\work\\graph")
    XCTAssertTrue(graph.nodes.isEmpty)
    XCTAssertTrue(graph.edges.isEmpty)

    XCTAssertThrowsError(
      try JSONDecoder().decode(
        LoopGraph.self,
        from: Data(#"{"nodes":[],"edges":[]}"#.utf8)))
  }

  func testPopulatedLoopGraphFixturesDecodeOrRejectInSwift() throws {
    let graph = try JSONDecoder().decode(
      LoopGraph.self, from: fixture("swift-loopgraph-populated-valid.json"))
    XCTAssertEqual(graph.nodes.count, 1)
    XCTAssertEqual(graph.edges.count, 1)
    XCTAssertEqual(graph.nodes.first?.subGraph?.nodes.count, 1)
    XCTAssertEqual(graph.nodes.first?.goal?.metricDirection, .minimize)
    XCTAssertEqual(graph.edges.first?.payloadTransform, .template("payload {{output}}"))
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        LoopGraph.self, from: fixture("swift-loopgraph-populated-invalid.json")))
  }

  func testGeneratePopulatedSwiftAcceptanceFixture() throws {
    let nested = LoopGraph(
      id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
      project: ProjectRef(path: "C:\\work\\nested", name: "Nested", lastOpenedAt: Date(timeIntervalSince1970: 1767225600)),
      nodes: IdentifiedArrayOf(uniqueElements: [
        LoopNode(
          id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
          title: "Nested loop",
          loopType: .composite,
          firstInstruction: "nested work",
          backend: .copilotCLI,
          createdAt: Date(timeIntervalSince1970: 1767225600))
      ]))
    let node = LoopNode(
      id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
      title: "Goal",
      loopType: .goalBased,
      checkDescription: "check",
      triggerPrompt: "trigger",
      firstInstruction: "work",
      pausesBeforeWritesOnly: true,
      goal: GoalSpec(
        summary: "finish", predicate: "test -f done", pollIntervalSeconds: 30,
        stallAfterSeconds: 600, metricCommand: "measure", metricDirection: .minimize),
      backend: .claudeCode,
      modelTier: .capable,
      worktreeBinding: WorktreeRef(
        id: "wt-1", repositoryPath: "C:\\repo", worktreePath: "C:\\repo-wt", branch: "feature"),
      subGraph: nested,
      pilotState: .armed,
      usage: UsageSample(inputTokens: 12, outputTokens: 34, costUSD: 0.12, reportedAt: Date(timeIntervalSince1970: 1767225600)),
      activity: "editing",
      presence: PresenceReading(presence: .busy, confidence: .reported),
      metricHistory: [MetricSample(value: 1.5, recordedAt: Date(timeIntervalSince1970: 1767225600))],
      createdBy: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
      state: .running,
      createdAt: Date(timeIntervalSince1970: 1767225600))
    let edge = LoopEdge(
      id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
      from: node.id,
      to: node.id,
      spec: EdgeSpec(
        kind: .handoff, condition: .onSuccess, payloadTransform: .template("payload {{output}}"),
        cycleGuard: CycleGuard(
          maxIterations: 3, until: "test -f done", stopAfterPassesWithoutImprovement: 2),
        spawnTargetProjectPath: "C:\\other"),
      fireCount: 1)
    let graph = LoopGraph(
      id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
      project: ProjectRef(path: "C:\\work\\graph", name: "Graph", lastOpenedAt: Date(timeIntervalSince1970: 1767225600)),
      nodes: IdentifiedArrayOf(uniqueElements: [node]),
      edges: IdentifiedArrayOf(uniqueElements: [edge]))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(graph)
    let roundTrip = try JSONDecoder().decode(LoopGraph.self, from: encoded)
    XCTAssertEqual(roundTrip.nodes.count, 1)
    XCTAssertEqual(roundTrip.edges.count, 1)
  }

  private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
  }

  private func fixtureURL(_ name: String) -> URL {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return root.appendingPathComponent("graphcode-windows/fixtures/\(name)")
  }
}

private struct RequestEnvelope: Decodable {
  let command: DaemonCommand
}
