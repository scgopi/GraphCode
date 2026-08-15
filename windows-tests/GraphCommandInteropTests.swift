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
