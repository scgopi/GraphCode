import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// What `GraphCommand.importNodes` does *after* the merge: imported unattended loops
/// get exactly what created ones get — a session, and a state that says so. Import
/// used to land everything `.idle` and start nothing, which every ensure path read as
/// "should be alive anyway": on a remote project the liveness sweep launched imported
/// loops within a minute with no goal poller to ever resolve them and a card still
/// claiming IDLE. The merge itself is covered where it lives, in `GraphImportPlanner`.
@Suite
struct GraphImportStartTests {
  private func snapshot(of nodes: [LoopNode], edges: [LoopEdge] = []) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/exported", name: "exported"),
      nodes: IdentifiedArray(uniqueElements: nodes),
      edges: IdentifiedArray(uniqueElements: edges))
  }

  @Test
  func importingAGoalLoopStartsItsSessionAndMarksItRunning() async {
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })
    let exported = LoopNode(
      title: "Green build", loopType: .goalBased,
      goal: GoalSpec(summary: "CI passes"), state: .running)

    await store.handle(.importNodes(GraphImportRequest(snapshot: snapshot(of: [exported]))))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].state == .running)
    #expect(graph.nodes[0].id != exported.id)
    #expect(started.value.map(\.id) == [graph.nodes[0].id])
  }

  @Test
  func importedResolvedLoopsKeepTheirVerdictAndStayUnstarted() async {
    // The bundle is the loop's history. Reborn `.idle`, a succeeded loop looked
    // unstarted to the remote liveness sweep, which re-ran the finished work.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })
    let done = LoopNode(
      title: "Shipped", loopType: .goalBased,
      goal: GoalSpec(summary: "released"), state: .succeeded)

    await store.handle(.importNodes(GraphImportRequest(snapshot: snapshot(of: [done]))))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].state == .succeeded)
    #expect(started.value.isEmpty)
  }

  @Test
  func importedTurnBasedLoopsStayIdleForAHumanToOpen() async {
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })
    let exported = LoopNode(
      title: "Review", loopType: .turnBased, checkDescription: "Sound?",
      firstInstruction: "Work", state: .running)

    await store.handle(.importNodes(GraphImportRequest(snapshot: snapshot(of: [exported]))))

    let graph = await store.graph
    #expect(graph.nodes.count == 1)
    #expect(graph.nodes[0].state == .idle)
    #expect(started.value.isEmpty)
  }

  @Test
  func reIdentifiedSnapshotsPreserveResolutionAndHeartbeats() {
    let succeeded = LoopNode(
      title: "Done", loopType: .goalBased, goal: GoalSpec(summary: "met"), state: .succeeded)
    let ticking = LoopNode(
      title: "Watcher", loopType: .timeBased, triggerPrompt: "check reports",
      heartbeatIntervalSeconds: 3600, state: .running)

    let prepared = GraphImportPlanner.reIdentified(
      GraphImportRequest(snapshot: snapshot(of: [succeeded, ticking])))

    let nodes = prepared?.request.snapshot.nodes
    #expect(nodes?.first(where: { $0.title == "Done" })?.state == .succeeded)
    #expect(nodes?.first(where: { $0.title == "Watcher" })?.state == .idle)
    #expect(nodes?.first(where: { $0.title == "Watcher" })?.heartbeatIntervalSeconds == 3600)
  }
}
