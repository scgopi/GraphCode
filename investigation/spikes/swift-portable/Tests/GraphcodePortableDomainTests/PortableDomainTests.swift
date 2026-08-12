import Foundation
import GraphcodePortableDomain
import XCTest

final class PortableDomainTests: XCTestCase {
  func testGraphRoundTripsWithAWindowsProjectPath() throws {
    let graph = LoopGraph(
      project: ProjectRef(
        path: #"C:\Projects\GraphCode Demo"#,
        name: "demo",
        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)))

    let data = try JSONEncoder().encode(graph)
    let decoded = try JSONDecoder().decode(LoopGraph.self, from: data)

    XCTAssertEqual(decoded.id, graph.id)
    XCTAssertEqual(decoded.nodes, graph.nodes)
    XCTAssertEqual(decoded.edges, graph.edges)
    XCTAssertEqual(decoded.project.path, #"C:\Projects\GraphCode Demo"#)
    XCTAssertEqual(decoded.project.name, "demo")
  }

  func testSettingsRoundTripUnchanged() throws {
    let settings = GraphcodeSettings()
    let data = try JSONEncoder().encode(settings)
    XCTAssertEqual(try JSONDecoder().decode(GraphcodeSettings.self, from: data), settings)
  }
}
