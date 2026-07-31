import Foundation
import Testing

@testable import GraphcodeKit

/// A loop that fans work out into more loops is the origin of them, and the graph has to
/// show that. Without the link, five loops a session creates are five nodes with no
/// inbound edge — which `LoopGraph.startAnchors` reads as five separate entry points, so
/// every canvas hangs them off the origin as though nothing had produced them.
@Suite
struct CreatedByLoopTests {
  private func draft(_ title: String, createdBy: UUID?) -> NodeDraft {
    NodeDraft(
      title: title, loopType: .goalBased, goal: GoalSpec(summary: "say hi"),
      createdBy: createdBy)
  }

  @Test
  func aSessionCanWorkOutWhichLoopItIs() {
    // The mechanism the whole feature rests on: `zmx` injects `ZMX_SESSION`, and
    // graphcode names its sessions after the node id.
    let id = UUID()
    let name = SurfaceRef(id: id, launchesClaudeCode: true).zmxSessionName
    #expect(SurfaceRef.nodeID(fromZmxSessionName: name) == id)
    // Anything that isn't one of ours is nobody — a human's own shell, or another tool's
    // session, must not be read as a loop.
    #expect(SurfaceRef.nodeID(fromZmxSessionName: "") == nil)
    #expect(SurfaceRef.nodeID(fromZmxSessionName: "my-shell") == nil)
    #expect(SurfaceRef.nodeID(fromZmxSessionName: "graphcode-not-a-uuid") == nil)
  }

  @Test
  func aChildInheritsItsCreatorsBackend() async throws {
    // A Copilot loop fanning work out must produce Copilot loops. The CLI used to
    // hardcode claudeCode as the draft default, so every agent-created child silently
    // switched provider — the wire couldn't tell "explicitly Claude" from "defaulted".
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Copilot triage", loopType: .goalBased,
          goal: GoalSpec(summary: "triage"), backend: .copilotCLI)))
    let parentID = try #require(await store.graph.nodes.first?.id)

    await store.handle(.createNode(draft("child", createdBy: parentID)))

    let child = try #require(await store.graph.nodes.first { $0.title == "child" })
    #expect(child.backend == .copilotCLI)
  }

  @Test
  func anExplicitBackendOnAChildIsNotSecondGuessed() async throws {
    // `--backend` names a choice; inheritance only fills silence.
    let store = GraphStore()
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Copilot triage", loopType: .goalBased,
          goal: GoalSpec(summary: "triage"), backend: .copilotCLI)))
    let parentID = try #require(await store.graph.nodes.first?.id)

    var explicit = draft("child", createdBy: parentID)
    explicit.backend = .claudeCode
    await store.handle(.createNode(explicit))

    let child = try #require(await store.graph.nodes.first { $0.title == "child" })
    #expect(child.backend == .claudeCode)
  }

  @Test
  func aParentlessDraftStillDefaultsToClaudeCode() async throws {
    // A human's shell has no creating loop; the resolution falls through to the same
    // default the CLI always had.
    let store = GraphStore()
    await store.handle(.createNode(draft("orphan", createdBy: nil)))
    let node = try #require(await store.graph.nodes.first)
    #expect(node.backend == .claudeCode)
  }

  @Test
  func loopsALoopCreatesHangOffItRatherThanOffTheGraphsOrigin() async throws {
    let store = GraphStore()
    await store.handle(.createNode(draft("triage", createdBy: nil)))
    let spinnerID = try #require(await store.graph.nodes.first?.id)

    for index in 1...5 {
      await store.handle(.createNode(draft("issue \(index)", createdBy: spinnerID)))
    }
    let graph = await store.graph

    #expect(graph.nodes.count == 6)
    // Five real edges, all from the loop that asked for them.
    #expect(graph.edges.filter { $0.from == spinnerID }.count == 5)
    // And the origin now tethers to the spinner alone, not to six scattered cards.
    #expect(graph.startAnchors == [spinnerID])
  }

  @Test
  func theHandoffIsRecordedAsAlreadyDoneSoTheNewLoopIsNotBlocked() async throws {
    // An unfired `.handoff` blocks its target, and these children are already running —
    // the daemon starts an unattended loop the moment it is created. Recording the
    // hand-off as complete says the true thing and leaves the child alone.
    let store = GraphStore()
    await store.handle(.createNode(draft("triage", createdBy: nil)))
    let spinnerID = try #require(await store.graph.nodes.first?.id)

    await store.handle(.createNode(draft("child", createdBy: spinnerID)))
    let graph = await store.graph
    let edge = graph.edges.first

    #expect(edge?.fired == true)
    #expect(edge?.kind == .handoff)
    let child = graph.nodes.first { $0.title == "child" }
    #expect(child?.state != .blocked)
  }

  @Test
  func aNodeAHumanCreatedHasNoCreatorEdge() async {
    // The form is not a loop. A node created from the app is genuinely parentless, and
    // inventing an edge for it would be a lie about how the graph came to be.
    let store = GraphStore()
    await store.handle(.createNode(draft("typed by hand", createdBy: nil)))
    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.edges.isEmpty)
  }

  @Test
  func aCreatorFromAnotherGraphIsIgnoredRatherThanInvented() async {
    // A session in one project can name a loop in another; a dangling edge pointing at a
    // node this graph has never heard of would be worse than no edge at all.
    let store = GraphStore()
    await store.handle(.createNode(draft("orphan", createdBy: UUID())))
    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.edges.isEmpty)
  }
}
