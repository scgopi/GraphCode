import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

@Suite
struct GoobersGraphExecutionTests {
  @Test
  func optingInStopsSessionsAndBlocksFutureSessionStarts() async {
    let existing = LoopNode(
      title: "Existing", loopType: .goalBased, goal: GoalSpec(summary: "Work"),
      backend: .copilotCLI)
    let killed = LockIsolated<[UUID]>([])
    let started = LockIsolated<[UUID]>([])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/project", name: "project"), nodes: [existing]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node.id) } },
      onTerminateSession: { node, _ in killed.withValue { $0.append(node.id) } },
      onGoobersEnabled: { true })

    await store.handle(.setExecutionMode(.goobers))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "New", loopType: .goalBased, goal: GoalSpec(summary: "More work"),
          backend: .copilotCLI)))

    let graph = await store.graph
    #expect(graph.executionMode == .goobers)
    #expect(killed.value == [existing.id])
    #expect(started.value.isEmpty)
    #expect(graph.nodes.last?.state == .idle)
  }

  @Test
  func theGoobersSettingMustBeOnBeforeAGraphCanOptIn() async {
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(
      onAnnounceError: { message in errors.withValue { $0.append(message) } },
      onGoobersEnabled: { false })

    await store.handle(.setExecutionMode(.goobers))

    #expect(await store.graph.executionMode == .graphcode)
    #expect(errors.value.first?.contains("enable Goobers orchestration") == true)
  }

  @Test
  func oneDispatchOwnsTheWholeGraphAndGraphCodeDoesNotFireItsEdges() async {
    let first = LoopNode(
      title: "Research", loopType: .turnBased, checkDescription: "Useful?",
      firstInstruction: "Research", backend: .copilotCLI)
    let second = LoopNode(
      title: "Report", loopType: .turnBased, checkDescription: "Clear?",
      firstInstruction: "Report", backend: .copilotCLI)
    var graph = LoopGraph(
      project: ProjectRef(path: "/tmp/project", name: "project"),
      nodes: [first, second])
    graph.edges = [LoopEdge(from: first.id, to: second.id, kind: .handoff)]
    let snapshots = LockIsolated<[LoopGraph]>([])
    let store = GraphStore(
      graph: graph,
      onGoobersEnabled: { true },
      onRunGoobers: { graph in
        snapshots.withValue { $0.append(graph) }
        return GoobersWorkspace.Dispatch(runID: "run-42", snapshotID: "snapshot-7")
      })

    await store.handle(.setExecutionMode(.goobers))
    await store.handle(.runGoobers)
    await store.handle(.nodeCheckApproved(first.id))

    let updated = await store.graph
    #expect(snapshots.value.count == 1)
    #expect(snapshots.value.first?.executionMode == .goobers)
    #expect(updated.goobersRun?.id == "run-42")
    #expect(updated.goobersRun?.snapshotID == "snapshot-7")
    #expect(updated.nodes[id: first.id]?.state == .succeeded)
    #expect(updated.nodes[id: second.id]?.state == .blocked)
    #expect(updated.edges.first?.fireCount == 0)
  }

  @Test
  func switchingBackStopsGoobersAndRestoresSessionExecution() async {
    let node = LoopNode(
      title: "Worker", loopType: .goalBased, goal: GoalSpec(summary: "Work"),
      backend: .copilotCLI)
    let stopped = LockIsolated<[UUID]>([])
    let started = LockIsolated<[UUID]>([])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/project", name: "project"), nodes: [node]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node.id) } },
      onGoobersEnabled: { true },
      onStopGoobers: { graphID in stopped.withValue { $0.append(graphID) } })

    await store.handle(.setExecutionMode(.goobers))
    let graphID = await store.graph.id
    await store.handle(.setExecutionMode(.graphcode))

    #expect(await store.graph.executionMode == .graphcode)
    #expect(stopped.value == [graphID])
    #expect(started.value == [node.id])
  }
}
