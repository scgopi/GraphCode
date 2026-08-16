import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// The distillation ask: the moment a goal loop resolves successfully, its still-live
/// session is asked — once — to fold a reusable method into the project's own skill
/// library. The graph curates, the backend executes; graphcode itself never writes
/// into the project.
@Suite
struct SkillDistillationTests {
  private func goalGraph() -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/distill", name: "distill"),
      nodes: [
        LoopNode(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "true"),
          state: .running)
      ])
  }

  @Test
  func aSucceedingGoalLoopIsAskedToDistillItsMethod() async {
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: goalGraph(),
      onEvaluatePredicate: { _ in true },
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      })
    let nodeID = await store.graph.nodes[0].id

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[0].state == .succeeded)
    #expect(delivered.value.contains { $0.contains("distill it into a project skill") })
  }

  @Test
  func anExitResolvedGoalIsNotAskedThereIsNobodyLeft() async {
    // `nodeCheckApproved` is the session-exit resolution path: the loop finished by
    // leaving. Only the predicate path proves the session is still there to ask.
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: goalGraph(),
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      })
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckApproved(nodeID))

    #expect(await store.graph.nodes[0].state == .succeeded)
    #expect(delivered.value.isEmpty)
  }

  @Test
  func aFailingResolutionAsksForNothing() async {
    // A failed loop's method is not a recipe.
    let delivered = LockIsolated<[String]>([])
    let store = GraphStore(
      graph: goalGraph(),
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      })
    let nodeID = await store.graph.nodes[0].id

    await store.handle(.nodeCheckRejected(nodeID))

    #expect(await store.graph.nodes[0].state == .failed)
    #expect(delivered.value.isEmpty)
  }

  @Test
  func aTurnBasedResolutionAsksForNothing() async {
    // The ask is scoped to goal loops: a turn-based loop resolves under a human's eye,
    // and that human decides what is worth keeping.
    let delivered = LockIsolated<[String]>([])
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/distill", name: "distill"),
      nodes: [
        LoopNode(title: "Review", checkDescription: "sound?", state: .running)
      ])
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      })

    await store.handle(.nodeCheckApproved(graph.nodes[0].id))

    #expect(await store.graph.nodes[0].state == .succeeded)
    #expect(delivered.value.isEmpty)
  }

  @Test
  func theAskSurvivesTheResolvedStateTheOrdinaryNudgeDrainWouldTripOn() async {
    // The regression this design dodged: resolution writes the very state
    // `MessageBus.deliverability` reads, so a resolved-but-live session is "not live"
    // to the graph. The ask must still reach the PTY.
    let node = LoopNode(
      title: "Green build", loopType: .goalBased,
      goal: GoalSpec(summary: "done", predicate: "true"),
      state: .running)
    #expect(MessageBus.deliverability(to: node) == nil)
    var resolved = node
    resolved.state = .succeeded
    #expect(MessageBus.deliverability(to: resolved) == .targetNotLive)
    // …which is exactly why the delivered-message assertion in the first test proves
    // the separate drain, not the ordinary one.
  }

  @Test
  func theBriefingTeachesTheSkillLibraryAndTheRefineVerb() throws {
    let briefing = try #require(
      SessionBriefing.text(projectPath: "/tmp/distill", settings: GraphcodeSettings()))
    #expect(briefing.contains(".claude/skills"))
    #expect(briefing.contains("Project skills"))
    #expect(briefing.contains("node refine"))
  }
}
