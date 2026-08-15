import Foundation
import XCTest

@testable import GraphcodeKit

final class GraphCommandInteropTests: XCTestCase {
  func testCreateEdgeWirePayloadDecodesToSwiftGraphCommand() throws {
    let json = #"{"version":2,"kind":"request","requestID":"00000000-0000-4000-8000-000000000003","command":{"graphCommand":{"projectPath":"C:\\work\\graph","command":{"createEdge":{"from":"11111111-1111-4111-8111-111111111111","to":"22222222-2222-4222-8222-222222222222","spec":{"kind":"handoff","condition":"always","payloadTransform":{"none":{}},"cycleGuard":null,"spawnTargetProjectPath":null}}}}}}"#
    let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: Data(json.utf8))
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
    let json = #"{"version":2,"kind":"request","requestID":"00000000-0000-4000-8000-000000000004","command":{"graphCommand":{"projectPath":"C:\\work\\graph","command":{"deleteEdge":{"_0":"33333333-3333-4333-8333-333333333333"}}}}}"#
    let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: Data(json.utf8))
    XCTAssertEqual(
      envelope.command,
      .graphCommand(
        projectPath: "C:\\work\\graph",
        command: .deleteEdge(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)))
  }
}

private struct RequestEnvelope: Decodable {
  let command: DaemonCommand
}
