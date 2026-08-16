import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Promotion is the reason the sketch type is worth having: a sketch that turned out
/// to matter keeps its session and gains a shape. What these guard is the identity
/// rule — same id, same edges, same memory key — and the one-field contract: each
/// target asks for exactly the thing it needs, and refuses without it.
@Suite
struct SketchPromotionTests {
  private func sketchDraft(_ title: String = "Poke around", note: String? = nil) -> NodeDraft {
    NodeDraft(title: title, loopType: .sketch, firstInstruction: note)
  }

  @Test
  func promotingToGoalKeepsIdentityAndStartsRunning() async {
    let store = GraphStore()
    let sketch = sketchDraft()
    let parent = NodeDraft(title: "Parent", loopType: .turnBased, firstInstruction: "Work")
    await store.handle(.createNode(parent))
    await store.handle(.createNode(sketch))
    await store.handle(.createEdge(from: parent.id, to: sketch.id, spec: EdgeSpec()))

    await store.handle(
      .promoteNode(sketch.id, promotion: .goal(GoalSpec(summary: "the flake is fixed"))))

    let graph = await store.graph
    let promoted = graph.nodes[id: sketch.id]
    // Same node, not a create + delete: the count is unchanged and the edge still
    // points at the same id.
    #expect(graph.nodes.count == 2)
    #expect(promoted?.loopType == .goalBased)
    #expect(promoted?.goal?.summary == "the flake is fixed")
    #expect(promoted?.state == .running)
    #expect(graph.edges.contains { $0.from == parent.id && $0.to == sketch.id })
  }

  @Test
  func promotingToGoalWithoutADoneCheckIsRefused() async {
    let store = GraphStore()
    let sketch = sketchDraft()
    await store.handle(.createNode(sketch))

    await store.handle(.promoteNode(sketch.id, promotion: .goal(GoalSpec(summary: "   "))))

    let graph = await store.graph
    #expect(graph.nodes[id: sketch.id]?.loopType == .sketch)
    #expect(graph.nodes[id: sketch.id]?.goal == nil)
  }

  @Test
  func onlyASketchCanBePromoted() async {
    let store = GraphStore()
    let turn = NodeDraft(title: "Review", loopType: .turnBased, firstInstruction: "Work")
    await store.handle(.createNode(turn))

    await store.handle(.promoteNode(turn.id, promotion: .goal(GoalSpec(summary: "done"))))

    let graph = await store.graph
    #expect(graph.nodes[id: turn.id]?.loopType == .turnBased)
    #expect(graph.nodes[id: turn.id]?.goal == nil)
  }

  @Test
  func promotingToTimedSetsTheCadenceAndStartsItsSession() async {
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in
      started.withValue { $0.append(node) }
    })
    let sketch = sketchDraft(note: "watch the crash reports")
    await store.handle(.createNode(sketch))

    await store.handle(
      .promoteNode(sketch.id, promotion: .timed(triggerPrompt: "/loop 1h watch the crash reports")))

    let graph = await store.graph
    let promoted = graph.nodes[id: sketch.id]
    #expect(promoted?.loopType == .timeBased)
    #expect(promoted?.triggerPrompt == "/loop 1h watch the crash reports")
    // A promoted unattended loop's session must exist whether or not the app is open —
    // the same guarantee creation gives the type.
    #expect(started.value.contains { $0.id == sketch.id })
  }

  @Test
  func promotingToTurnSetsWhereItPauses() async {
    let store = GraphStore()
    let sketch = sketchDraft()
    await store.handle(.createNode(sketch))

    await store.handle(.promoteNode(sketch.id, promotion: .turn(pausesBeforeWritesOnly: true)))

    let graph = await store.graph
    let promoted = graph.nodes[id: sketch.id]
    #expect(promoted?.loopType == .turnBased)
    #expect(promoted?.pausesBeforeWritesOnly == true)
    // A turn loop starts when a human opens it — promotion doesn't set it running.
    #expect(promoted?.state == .idle)
  }

  @Test
  func theFormBuildsThePromotionFromItsOneField() {
    var state = ProjectFeature.State(
      graph: LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p")))
    let sketch = LoopNode(title: "Poke", loopType: .sketch, firstInstruction: "read the RFC")
    state.graph.nodes.append(sketch)
    state.nodePendingPromotion = sketch.id

    state.promotionTarget = .goalBased
    #expect(state.promotion == nil)  // empty done check → nothing to send
    state.promotionGoal = "the RFC is summarised"
    #expect(state.promotion == .goal(GoalSpec(summary: "the RFC is summarised")))

    // The cadence is the only asked-for field; the work it repeats is the sketch's own
    // note when there is one.
    state.promotionTarget = .timeBased
    state.promotionInterval = .hourly
    #expect(state.promotion == .timed(triggerPrompt: "/loop 1h read the RFC"))

    state.promotionTarget = .turnBased
    state.promotionPausesBeforeWritesOnly = true
    #expect(state.promotion == .turn(pausesBeforeWritesOnly: true))
  }

  /// Demotion is unrepresentable rather than refused: no `SketchPromotion` case lands
  /// on `.sketch` or `.composite`, so the wire cannot carry one.
  @Test
  func everyPromotionLandsOnACommittedSessionType() {
    let targets: [LoopType] = [
      SketchPromotion.goal(GoalSpec(summary: "x")).targetType,
      SketchPromotion.turn(pausesBeforeWritesOnly: false).targetType,
      SketchPromotion.timed(triggerPrompt: "/loop 1h x").targetType,
    ]
    #expect(targets == [.goalBased, .turnBased, .timeBased])
  }
}
