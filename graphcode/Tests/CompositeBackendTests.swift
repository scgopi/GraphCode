import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit

/// Which backend a composite's workers run on. Its own suite because
/// `CompositeAndGlobalGraphTests` sits at the lint budget's type-body limit.
@Suite
struct CompositeBackendTests {
  @Test
  func aLoopAddedInsideACompositeRunsOnTheCompositesBackend() async {
    // A Copilot composite must produce Copilot workers. The draft the app or the CLI
    // sends for a loop inside a composite names no backend unless the human picked one,
    // and `NodeDraft.effectiveBackend` would have fallen to Claude Code — a composite
    // labelled Copilot whose every worker ran a different agent.
    let composite = LoopNode(
      title: "Triage inbox", loopType: .composite, backend: .copilotCLI,
      subGraph: LoopGraph(project: ProjectRef(path: "sub", name: "sub"), nodes: []))
    let store = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [composite]))

    await store.handle(
      .subGraphCommand(
        nodeID: composite.id,
        command: .createNode(
          NodeDraft(title: "Classify", loopType: .goalBased, goal: GoalSpec(summary: "sorted")))))
    await store.handle(
      .subGraphCommand(
        nodeID: composite.id,
        command: .createNode(
          NodeDraft(
            title: "Explicit", loopType: .goalBased, goal: GoalSpec(summary: "sorted"),
            backend: .codex))))

    let workers = await store.graph.nodes[id: composite.id]?.subGraph?.nodes
    #expect(workers?.first(where: { $0.title == "Classify" })?.backend == .copilotCLI)
    // A backend the human named still wins over the composite's.
    #expect(workers?.first(where: { $0.title == "Explicit" })?.backend == .codex)
  }
  @Test
  func pilotingACopilotCompositeStartsItsWorkersOnCopilot() async {
    // The whole path a human takes: a composite on Copilot, a worker added inside it
    // with no backend named, then Pilot. The session the daemon is asked to start
    // must be a Copilot one — the composite's label has to be the truth about its
    // workers, or the picker allowing the pairing means nothing.
    let started = LockIsolated<[LoopNode]>([])
    let composite = LoopNode(
      title: "Nightly sweep", loopType: .composite, backend: .copilotCLI,
      subGraph: LoopGraph(project: ProjectRef(path: "sub", name: "sub"), nodes: []))
    let store = GraphStore(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [composite]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(
      .subGraphCommand(
        nodeID: composite.id,
        command: .createNode(
          NodeDraft(title: "Sweep", loopType: .goalBased, goal: GoalSpec(summary: "swept")))))
    #expect(started.value.isEmpty)

    await store.handle(.pilotComposite(composite.id))

    #expect(started.value.map(\.title) == ["Sweep"])
    #expect(started.value.first?.backend == .copilotCLI)
    #expect(await store.graph.nodes[id: composite.id]?.pilotState == .piloted)
  }
}
