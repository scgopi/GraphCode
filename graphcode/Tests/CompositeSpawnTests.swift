import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import GraphcodeKit

/// Spawning a `.composite` template — the case where "one loop generates another" has to
/// carry a whole nested routine across, not just a handful of scalar fields.
@Suite
struct CompositeSpawnTests {
  private func compositeTemplate(subNodes: [LoopNode]) -> LoopNode {
    LoopNode(
      title: "Triage",
      loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: IdentifiedArray(uniqueElements: subNodes)),
      pilotState: .armed)
  }

  @Test
  func spawningACompositeCarriesItsRoutine() async {
    // Without this the spawn produced a composite node with no sub-graph at all: it can't
    // be piloted, can't be run, and does nothing — a node that merely looks busy.
    let trigger = LoopNode(title: "Watch", state: .idle)
    let template = compositeTemplate(subNodes: [
      LoopNode(title: "Classify", loopType: .timeBased, triggerPrompt: "/loop 1h Check"),
      LoopNode(title: "Reply", checkDescription: "Sound?"),
    ])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [trigger, template],
        edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)]))

    await store.handle(.nodeCheckApproved(trigger.id))

    let instance = try? #require(await store.graph.nodes.last)
    #expect(instance?.title == "Triage #2")
    #expect(instance?.subGraph?.nodes.count == 2)
  }

  @Test
  func aSpawnedCompositesSubLoopsGetFreshIdentities() async {
    // A node's id *is* its `zmx` session name, so a value-copied sub-graph would have
    // every instance attaching to the template's own terminals — two instances driving
    // one session.
    let trigger = LoopNode(title: "Watch", state: .idle)
    let template = compositeTemplate(subNodes: [LoopNode(title: "Classify")])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [trigger, template],
        edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)]))
    let templateChildID = try? #require(template.subGraph?.nodes.first?.id)

    await store.handle(.nodeCheckApproved(trigger.id))

    let instanceChildID = await store.graph.nodes.last?.subGraph?.nodes.first?.id
    #expect(instanceChildID != nil)
    #expect(instanceChildID != templateChildID)
    // The template itself is untouched, ready to be spawned from again.
    #expect(await store.graph.nodes[id: template.id]?.subGraph?.nodes.first?.id == templateChildID)
  }

  @Test
  func reIdentifyingAGraphKeepsItsShape() {
    // Fresh ids are only useful if the wiring survives them.
    let first = LoopNode(title: "A")
    let second = LoopNode(title: "B")
    let original = LoopGraph(
      project: ProjectRef(path: "sub", name: "sub"),
      nodes: [first, second],
      edges: [
        LoopEdge(from: first.id, to: second.id, kind: .handoff, condition: .onSuccess)
      ])

    let copy = original.reIdentified()

    #expect(copy.nodes.count == 2)
    #expect(copy.edges.count == 1)
    #expect(copy.nodes.map(\.title) == ["A", "B"])
    // Endpoints were remapped, not left pointing at the original's nodes.
    #expect(copy.edges[0].from == copy.nodes[0].id)
    #expect(copy.edges[0].to == copy.nodes[1].id)
    #expect(copy.edges[0].condition == .onSuccess)
    // Nothing is shared with the original.
    #expect(copy.nodes[0].id != first.id)
    #expect(copy.id != original.id)
  }

  @Test
  func reIdentifyingRecursesIntoNestedComposites() {
    // A composite inside a composite needs the same treatment for the same reason.
    let grandchild = LoopNode(title: "Deep")
    let child = LoopNode(
      title: "Middle", loopType: .composite,
      subGraph: LoopGraph(project: ProjectRef(path: "s", name: "s"), nodes: [grandchild]))
    let original = LoopGraph(project: ProjectRef(path: "sub", name: "sub"), nodes: [child])

    let copy = original.reIdentified()

    let copiedGrandchildID = copy.nodes[0].subGraph?.nodes[0].id
    #expect(copiedGrandchildID != nil)
    #expect(copiedGrandchildID != grandchild.id)
  }

  @Test
  func aSpawnedCompositeStartsItsSubLoops() async {
    // Instantiating a routine has to actually run it — otherwise the spawn produces
    // something that reports `.running` while nothing is happening inside it.
    let started = LockIsolated<[String]>([])
    let trigger = LoopNode(title: "Watch", state: .idle)
    let template = compositeTemplate(subNodes: [
      LoopNode(title: "Poll", loopType: .timeBased, triggerPrompt: "/loop 1h Check"),
      LoopNode(title: "Review", checkDescription: "?"),
    ])
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [trigger, template],
        edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)]),
      onEnsureSession: { node, _ in started.withValue { $0.append(node.title) } })

    await store.handle(.nodeCheckApproved(trigger.id))

    // Only the unattended one — a turn-based sub-loop waits for a human, as always.
    #expect(started.value == ["Poll"])
    let instance = await store.graph.nodes.last
    #expect(instance?.state == .running)
    // Deliberately armed: a spawned composite is one live run, not a routine waiting for
    // someone to pilot it. Left `.notPiloted` it could never do anything.
    #expect(instance?.pilotState == .armed)
  }

  @Test
  func aCrossGraphSpawnCarriesTheRoutineToo() async {
    // Same failure, different path: the receiving project would otherwise get an empty
    // composite that looks right and does nothing.
    let requests = LockIsolated<[NodeDraft]>([])
    let trigger = LoopNode(title: "Watch inbox", state: .idle)
    let template = compositeTemplate(subNodes: [LoopNode(title: "Classify")])
    let store = GraphStore(
      graph: LoopGraph(
        scope: .global,
        nodes: [trigger, template],
        edges: [
          LoopEdge(
            from: trigger.id, to: template.id, kind: .spawn,
            spawnTargetProjectPath: "/tmp/target")
        ]),
      onSpawnIntoProject: { _, draft in requests.withValue { $0.append(draft) } })

    await store.handle(.nodeCheckApproved(trigger.id))

    #expect(requests.value.first?.subGraph?.nodes.count == 1)
    // And the draft still builds a node with its own identities.
    let built = requests.value.first?.makeNode()
    #expect(built?.subGraph?.nodes.first?.id != template.subGraph?.nodes.first?.id)
  }

  @Test
  func spawningANonCompositeStillCarriesNoSubGraph() async {
    // The other three loop types have nothing nested to bring; this pins that the new
    // handling didn't give them one.
    let trigger = LoopNode(title: "Watch", state: .idle)
    let template = LoopNode(title: "Worker", checkDescription: "?")
    let store = GraphStore(
      graph: LoopGraph(
        project: ProjectRef(path: "/tmp/p", name: "p"),
        nodes: [trigger, template],
        edges: [LoopEdge(from: trigger.id, to: template.id, kind: .spawn)]))

    await store.handle(.nodeCheckApproved(trigger.id))

    let instance = await store.graph.nodes.last
    #expect(instance?.subGraph == nil)
    #expect(instance?.state == .idle)
    #expect(instance?.pilotState == .notPiloted)
  }
}
