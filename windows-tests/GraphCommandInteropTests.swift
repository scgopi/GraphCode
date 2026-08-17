import Foundation
import XCTest

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

  private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("graphcode-windows/fixtures/\(name)"))
  }
}

private struct RequestEnvelope: Decodable {
  let command: DaemonCommand
}
