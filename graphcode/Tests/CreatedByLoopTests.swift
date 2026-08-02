import ComposableArchitecture
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
  func aChildIsHandedTheReportBackRouteAtBirth() async throws {
    // A Copilot child was observed inventing routes through its own platform's
    // features when the time came to report results — the briefing describes
    // `node send` in general terms, but a backend that only skims it needs the
    // command spelled out. It goes into the child's memory before its session
    // launches, so the wake digest opens with it.
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onAppendMemory: { nodeID, entry in memory.withValue { $0.append((nodeID, entry)) } })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)

    await store.handle(.createNode(draft("child", createdBy: parentID)))

    let child = try #require(await store.graph.nodes.first { $0.title == "child" })
    let route = try #require(memory.value.first { $0.nodeID == child.id }?.entry)
    #expect(route.contains("graphcode node send"))
    #expect(route.contains(parentID.uuidString))
    #expect(route.contains("created by parent"))
  }

  @Test
  func aMessageToAResolvedTargetIsStagedNotDropped() async throws {
    // The refusal predated loops having memory; its sharpest edge was a child
    // reporting results to a parent that had already resolved — the report vanished.
    let memory = LockIsolated<[(nodeID: UUID, entry: String)]>([])
    let store = GraphStore(
      onDeliverMessage: { _, _, _ in
        Issue.record("a resolved target has no live session to type into")
        return false
      },
      onAppendMemory: { nodeID, entry in memory.withValue { $0.append((nodeID, entry)) } })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)
    await store.handle(.nodeCheckApproved(parentID))

    await store.handle(.messageNode(parentID, text: "task done: report attached", from: nil))

    let staged = memory.value.filter {
      $0.nodeID == parentID && $0.entry.contains("while you were away")
    }
    #expect(staged.count == 1)
    #expect(staged[0].entry.contains("task done: report attached"))
  }

  @Test
  func stoppingALoopAsksItsSessionRatherThanKillingIt() async throws {
    // Stopping is the reversible verb: the agent, its transcript, and its scrollback all
    // survive, and the loop gets to cancel the cadence it set up — a cron entry or a
    // scheduled wakeup outlives a killed PTY and would keep firing at a stopped loop.
    let asked = LockIsolated<[String]>([])
    let terminated = LockIsolated<[String]>([])
    let store = GraphStore(
      onTerminateSession: { node, _ in terminated.withValue { $0.append(node.title) } },
      onDeliverMessage: { node, text, _ in
        if text == MessageBus.stopRequest { asked.withValue { $0.append(node.title) } }
        return true
      })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)
    await store.handle(.createNode(draft("child", createdBy: parentID)))

    await store.handle(.stopNode(parentID))

    #expect(await store.graph.nodes[id: parentID]?.state == .stopped)
    #expect(Set(asked.value) == ["parent", "child"])
    #expect(terminated.value.isEmpty)
  }

  @Test
  func aLoopThatCannotBeAskedToStopIsKilledInstead() async throws {
    // "Stopped" has to mean stopped: a request nobody can receive would otherwise leave
    // the loop running with the graph claiming it isn't.
    let terminated = LockIsolated<[String]>([])
    let store = GraphStore(
      onTerminateSession: { node, _ in terminated.withValue { $0.append(node.title) } },
      onDeliverMessage: { _, _, _ in false })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)

    await store.handle(.stopNode(parentID))

    #expect(await store.graph.nodes[id: parentID]?.state == .stopped)
    #expect(terminated.value == ["parent"])
  }

  @Test
  func stoppingAParentStopsItsSpawnedDescendantsButNotPeers() async throws {
    // A stopped coordinator must not leave the workers it fanned out running headless —
    // and a drawn edge to a peer is a relationship, not custody, so the peer survives.
    // Only the stop requests count: the peer's own handoff nudge rides the same
    // transport, and it is the thing being asserted absent.
    let stopped = LockIsolated<[String]>([])
    let store = GraphStore(
      onDeliverMessage: { node, text, _ in
        if text == MessageBus.stopRequest { stopped.withValue { $0.append(node.title) } }
        return true
      })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)
    await store.handle(.createNode(draft("child", createdBy: parentID)))
    let childID = try #require(await store.graph.nodes.first { $0.title == "child" }?.id)
    await store.handle(.createNode(draft("grandchild", createdBy: childID)))
    await store.handle(.createNode(draft("peer", createdBy: nil)))
    let peerID = try #require(await store.graph.nodes.first { $0.title == "peer" }?.id)
    await store.handle(.createEdge(from: parentID, to: peerID, spec: EdgeSpec()))

    await store.handle(.stopNode(parentID))

    let graph = await store.graph
    #expect(graph.nodes[id: parentID]?.state == .stopped)
    #expect(graph.nodes[id: childID]?.state == .stopped)
    #expect(graph.nodes.first { $0.title == "grandchild" }?.state == .stopped)
    #expect(graph.nodes[id: peerID]?.state != .stopped)
    #expect(Set(stopped.value) == ["parent", "child", "grandchild"])
  }

  @Test
  func deletingAParentDeletesItsSpawnedDescendants() async throws {
    // Deleting a coordinator takes its fan-out tree — sessions, edges, memory — while
    // an ordinary peer connected by a drawn edge stays in the graph.
    let removedMemory = LockIsolated<[UUID]>([])
    let store = GraphStore(
      onRemoveMemory: { nodeID in removedMemory.withValue { $0.append(nodeID) } })
    await store.handle(.createNode(draft("parent", createdBy: nil)))
    let parentID = try #require(await store.graph.nodes.first?.id)
    await store.handle(.createNode(draft("child", createdBy: parentID)))
    let childID = try #require(await store.graph.nodes.first { $0.title == "child" }?.id)
    await store.handle(.createNode(draft("peer", createdBy: nil)))
    let peerID = try #require(await store.graph.nodes.first { $0.title == "peer" }?.id)

    await store.handle(.deleteNode(parentID))

    let graph = await store.graph
    #expect(graph.nodes[id: parentID] == nil)
    #expect(graph.nodes[id: childID] == nil)
    #expect(graph.nodes[id: peerID] != nil)
    #expect(graph.edges.isEmpty)
    #expect(Set(removedMemory.value) == [parentID, childID])
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
