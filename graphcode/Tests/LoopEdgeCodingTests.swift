import Foundation
import GraphcodeKit
import Testing

/// `ProjectPersistence.loadGraph` turns any decode failure into "no saved graph", which
/// a user would read as their project's loops having been wiped. So every shape a
/// `LoopEdge` has ever been persisted in has to keep decoding — these tests pin the
/// oldest ones against raw JSON rather than against whatever the current struct happens
/// to encode.
@Suite
struct LoopEdgeCodingTests {
  private func decode(_ json: String) throws -> LoopEdge {
    try JSONDecoder().decode(LoopEdge.self, from: Data(json.utf8))
  }

  @Test
  func aPrePayloadTransformEdgeStillDecodes() throws {
    // The Phase 2–4 shape: `payloadNote` instead of `payloadTransform`.
    let edge = try decode(
      """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "from": "00000000-0000-0000-0000-000000000002",
        "to": "00000000-0000-0000-0000-000000000003",
        "kind": "handoff",
        "condition": "always",
        "payloadNote": "the failing test name",
        "fired": true
      }
      """)

    #expect(edge.kind == .handoff)
    #expect(edge.fired == true)
    // A legacy note was free text describing the handoff — that's a `.template`.
    #expect(edge.payloadTransform == .template("the failing test name"))
  }

  @Test
  func aLegacyEdgeWithNoNoteDecodesToNoTransform() throws {
    let edge = try decode(
      """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "from": "00000000-0000-0000-0000-000000000002",
        "to": "00000000-0000-0000-0000-000000000003",
        "kind": "spawn",
        "condition": "onFailure",
        "fired": false
      }
      """)

    #expect(edge.payloadTransform == .none)
    #expect(edge.kind == .spawn)
    #expect(edge.condition == .onFailure)
  }

  @Test
  func aMinimalEdgeFallsBackToHandoffAlways() throws {
    // Defensive: only the three identity fields are actually required. Anything missing
    // decodes to the same defaults `LoopEdge.init` uses, so a truncated or
    // partially-written file degrades to a plain handoff rather than losing the graph.
    let edge = try decode(
      """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "from": "00000000-0000-0000-0000-000000000002",
        "to": "00000000-0000-0000-0000-000000000003"
      }
      """)

    #expect(edge.kind == .handoff)
    #expect(edge.condition == .always)
    #expect(edge.fired == false)
    #expect(edge.payloadTransform == .none)
  }

  @Test
  func currentEdgesRoundTrip() throws {
    for transform in [PayloadTransform.none, .template("a note"), .script("make test")] {
      let original = LoopEdge(
        from: UUID(), to: UUID(), kind: .message, condition: .onSuccess,
        payloadTransform: transform, fireCount: 1)
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(LoopEdge.self, from: data)
      #expect(decoded == original)
    }
  }

  @Test
  func aWholeGraphOfLegacyEdgesSurvivesTheLoad() throws {
    // The failure that actually matters: one un-migratable edge taking the entire
    // project's graph down with it.
    let json = """
      {
        "id": "00000000-0000-0000-0000-0000000000AA",
        "project": {
          "path": "/tmp/legacy",
          "name": "legacy",
          "lastOpenedAt": 0
        },
        "nodes": [],
        "edges": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "from": "00000000-0000-0000-0000-000000000002",
            "to": "00000000-0000-0000-0000-000000000003",
            "kind": "handoff",
            "condition": "always",
            "payloadNote": "diff",
            "fired": false
          }
        ]
      }
      """

    let graph = try JSONDecoder().decode(LoopGraph.self, from: Data(json.utf8))
    #expect(graph.edges.count == 1)
    #expect(graph.edges[0].payloadTransform == .template("diff"))
  }
}
