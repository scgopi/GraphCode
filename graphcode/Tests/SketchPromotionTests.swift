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
      .promoteNode(
        sketch.id, promotion: .goal(GoalSpec(summary: "the flake is fixed")), promotedBy: nil))

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

    await store.handle(
      .promoteNode(sketch.id, promotion: .goal(GoalSpec(summary: "   ")), promotedBy: nil))

    let graph = await store.graph
    #expect(graph.nodes[id: sketch.id]?.loopType == .sketch)
    #expect(graph.nodes[id: sketch.id]?.goal == nil)
  }

  @Test
  func onlyASketchCanBePromoted() async {
    let store = GraphStore()
    let turn = NodeDraft(title: "Review", loopType: .turnBased, firstInstruction: "Work")
    await store.handle(.createNode(turn))

    await store.handle(
      .promoteNode(turn.id, promotion: .goal(GoalSpec(summary: "done")), promotedBy: nil))

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
      .promoteNode(
        sketch.id, promotion: .timed(triggerPrompt: "/loop 1h watch the crash reports"),
        promotedBy: nil))

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

    await store.handle(
      .promoteNode(sketch.id, promotion: .turn(pausesBeforeWritesOnly: true), promotedBy: nil))

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

  /// `updateNode`'s one rule with teeth, held at promotion too: a loop may not hand
  /// *itself* a stop condition. Without this, self-promotion was the open back door —
  /// promote yourself to goal with `predicate: "true"` and you have written and passed
  /// your own verifier in one command.
  @Test
  func selfPromotionMayNotCarryAPredicate() async {
    let entries = LockIsolated<[String]>([])
    let store = GraphStore(onAppendMemory: { _, entry in
      entries.withValue { $0.append(entry) }
    })
    let sketch = sketchDraft()
    await store.handle(.createNode(sketch))

    await store.handle(
      .promoteNode(
        sketch.id,
        promotion: .goal(GoalSpec(summary: "done", predicate: "true")),
        promotedBy: sketch.id))

    let graph = await store.graph
    #expect(graph.nodes[id: sketch.id]?.loopType == .sketch)
    #expect(graph.nodes[id: sketch.id]?.goal == nil)
    #expect(entries.value.contains { $0.contains("may not set its own stop condition") })
  }

  /// The refusal is about the predicate, not about self-promotion: prose states the
  /// goal without passing it, so a loop giving itself a summary-only shape stays legal.
  @Test
  func summaryOnlySelfPromotionIsAllowed() async {
    let store = GraphStore()
    let sketch = sketchDraft()
    await store.handle(.createNode(sketch))

    await store.handle(
      .promoteNode(
        sketch.id, promotion: .goal(GoalSpec(summary: "the report is filed")),
        promotedBy: sketch.id))

    let graph = await store.graph
    #expect(graph.nodes[id: sketch.id]?.loopType == .goalBased)
    #expect(graph.nodes[id: sketch.id]?.goal?.summary == "the report is filed")
  }

  /// The verifier stays outside the verified — and anyone outside may set it: a peer
  /// promoting a sketch can carry a predicate, exactly like a human's shell.
  @Test
  func aPeerMayPromoteWithAPredicate() async {
    let store = GraphStore()
    let reviewer = NodeDraft(title: "Reviewer", loopType: .turnBased, firstInstruction: "Judge")
    let sketch = sketchDraft()
    await store.handle(.createNode(reviewer))
    await store.handle(.createNode(sketch))

    await store.handle(
      .promoteNode(
        sketch.id,
        promotion: .goal(GoalSpec(summary: "tests pass", predicate: "make test")),
        promotedBy: reviewer.id))

    let graph = await store.graph
    #expect(graph.nodes[id: sketch.id]?.loopType == .goalBased)
    #expect(graph.nodes[id: sketch.id]?.goal?.predicate == "make test")
  }

  /// Provenance reaches the diary the way `updateNode`'s does: the promoter's title
  /// when a loop asked, "itself" for a self-promotion, "a human" otherwise.
  @Test
  func theDiaryNamesThePromoter() async {
    let entries = LockIsolated<[String]>([])
    let store = GraphStore(onAppendMemory: { _, entry in
      entries.withValue { $0.append(entry) }
    })
    let parent = NodeDraft(title: "Coordinator", loopType: .turnBased, firstInstruction: "Run")
    let bySelf = sketchDraft("Solo")
    let byPeer = sketchDraft("Delegated")
    let byHuman = sketchDraft("Handled")
    await store.handle(.createNode(parent))
    for draft in [bySelf, byPeer, byHuman] { await store.handle(.createNode(draft)) }

    await store.handle(
      .promoteNode(
        bySelf.id, promotion: .goal(GoalSpec(summary: "a")), promotedBy: bySelf.id))
    await store.handle(
      .promoteNode(
        byPeer.id, promotion: .goal(GoalSpec(summary: "b")), promotedBy: parent.id))
    await store.handle(
      .promoteNode(byHuman.id, promotion: .goal(GoalSpec(summary: "c")), promotedBy: nil))

    let promotions = entries.value.filter { $0.contains("promoted from main") }
    #expect(promotions.contains { $0.contains("by itself") })
    #expect(promotions.contains { $0.contains("by Coordinator") })
    #expect(promotions.contains { $0.contains("by a human") })
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
