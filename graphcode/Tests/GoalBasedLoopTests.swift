import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Goal-based loops: the fourth taxonomy primitive, and the only one whose resolution
/// `graphcoded` reaches out and *checks* rather than waiting to be told about
/// (docs/05-orchestrator.md#responsibilities item 4).
///
/// Every test drives `evaluateGoal` directly rather than waiting on the poll timer —
/// the timer is a one-line `Task.sleep` loop around exactly this call, and testing
/// through it would only buy flakiness.
@Suite
struct GoalBasedLoopTests {
  private func store(goalMet: Bool = false) -> GraphStore {
    GraphStore(onEvaluatePredicate: { _ in goalMet })
  }

  @Test
  func aGoalBasedNodeStartsRunningWithItsSessionUp() async {
    // Unlike every other node type it doesn't wait in `.idle`: there's no human turn
    // and no trigger between creation and the work starting.
    let started = LockIsolated<[LoopNode]>([])
    let store = GraphStore(onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))

    let graph = await store.graph
    #expect(graph.nodes[0].loopType == .goalBased)
    #expect(graph.nodes[0].state == .running)
    #expect(graph.nodes[0].goal?.summary == "CI passes")
    #expect(started.value.count == 1)
  }

  @Test
  func aMetPredicateResolvesTheNodeAndFiresItsEdges() async {
    let store = store(goalMet: true)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))

    await store.evaluateGoal(nodes[0].id)

    let graph = await store.graph
    #expect(graph.nodes[id: nodes[0].id]?.state == .succeeded)
    #expect(graph.edges[0].fired == true)
    #expect(graph.nodes[id: nodes[1].id]?.state == .idle)
  }

  @Test
  func anUnmetPredicateLeavesTheNodeRunning() async {
    let store = store(goalMet: false)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[id: nodeID]?.state == .running)
  }

  @Test
  func aGoalWithNoPredicateIsNeverResolvedByPolling() async {
    // A prose-only goal resolves when its session exits, like any other loop. If polling
    // could resolve it, an evaluator returning `true` by default would silently finish
    // every such node the moment it was created.
    let store = store(goalMet: true)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Readable docs", loopType: .goalBased,
          goal: GoalSpec(summary: "The doc reads well"))))
    let nodeID = await store.graph.nodes[0].id

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[id: nodeID]?.state == .running)
  }

  @Test
  func aWhitespaceOnlyPredicateCountsAsNoPredicate() async {
    // A human tabbing through the field must not produce a command that always exits 0.
    let spec = GoalSpec(summary: "Done", predicate: "   ")
    #expect(spec.effectivePredicate == nil)

    let store = store(goalMet: true)
    await store.handle(.createNode(NodeDraft(title: "Loose", loopType: .goalBased, goal: spec)))
    let nodeID = await store.graph.nodes[0].id

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[id: nodeID]?.state == .running)
  }

  @Test
  func blowingTheStallBoundMarksItStalledWithoutEvaluatingThePredicate() async {
    let evaluated = LockIsolated(0)
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/goal", name: "goal"),
      nodes: [
        LoopNode(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test", stallAfterSeconds: 60),
          state: .running,
          createdAt: Date(timeIntervalSince1970: 0))
      ])
    let store = GraphStore(
      graph: graph,
      onEvaluatePredicate: { _ in
        evaluated.withValue { $0 += 1 }
        return false
      })
    let nodeID = graph.nodes[0].id

    await store.evaluateGoal(nodeID, now: Date(timeIntervalSince1970: 61))

    #expect(await store.graph.nodes[id: nodeID]?.state == .stalled)
    #expect(
      await store.graph.nodes[id: nodeID]?.stallReason == "stall bound exceeded without resolving")
    #expect(evaluated.value == 0)
  }

  @Test
  func aStalledNodeStillReleasesWhateverWasWaitingOnIt() async {
    // Leaving a stalled loop's edges unfired would deadlock everything downstream, so a
    // stall fires them as a failure rather than not at all.
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/goal", name: "goal"),
      nodes: [
        LoopNode(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test", stallAfterSeconds: 1),
          state: .running,
          createdAt: Date(timeIntervalSince1970: 0)),
        LoopNode(title: "Escalate", loopType: .turnBased, checkDescription: "?"),
      ])
    let store = GraphStore(graph: graph, onEvaluatePredicate: { _ in false })
    let (goalID, escalateID) = (graph.nodes[0].id, graph.nodes[1].id)
    await store.handle(
      .createEdge(from: goalID, to: escalateID, spec: EdgeSpec(condition: .onFailure)))

    await store.evaluateGoal(goalID, now: Date(timeIntervalSince1970: 3600))

    let updated = await store.graph
    #expect(updated.nodes[id: goalID]?.state == .stalled)
    #expect(updated.edges[0].fired == true)
    #expect(updated.nodes[id: escalateID]?.state == .idle)
  }

  @Test
  func anAlreadyResolvedGoalIsNotResolvedTwice() async {
    let store = store(goalMet: true)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id
    // Its session exited and failed before the poll came back — that verdict stands.
    await store.handle(.nodeCheckRejected(nodeID))

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes[id: nodeID]?.state == .failed)
  }

  @Test
  func aProseOnlyGoalCanStillStall() async {
    // No predicate to evaluate, but a bound its author set is still worth enforcing —
    // "this should have finished by now" doesn't need a shell command to be true.
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/goal", name: "goal"),
      nodes: [
        LoopNode(
          title: "Readable docs", loopType: .goalBased,
          goal: GoalSpec(summary: "The doc reads well", stallAfterSeconds: 60),
          state: .running,
          createdAt: Date(timeIntervalSince1970: 0))
      ])
    let store = GraphStore(graph: graph, onEvaluatePredicate: { _ in true })

    await store.evaluateGoal(graph.nodes[0].id, now: Date(timeIntervalSince1970: 61))

    #expect(await store.graph.nodes[0].state == .stalled)
  }

  @Test
  func evaluatingADeletedNodeIsANoOpNotACrash() async {
    let store = store(goalMet: true)
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"))))
    let nodeID = await store.graph.nodes[0].id
    await store.handle(.deleteNode(nodeID))

    await store.evaluateGoal(nodeID)

    #expect(await store.graph.nodes.isEmpty)
  }

  @Test
  func aResolvedGoalIsNotRestartedWhenItsProjectReloads() async {
    // Re-pursuing a met goal would restart work the graph already recorded as finished.
    let started = LockIsolated<[LoopNode]>([])
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/goal", name: "goal"),
      nodes: [
        LoopNode(
          title: "Green build", loopType: .goalBased,
          goal: GoalSpec(summary: "CI passes", predicate: "make test"),
          state: .succeeded),
        LoopNode(
          title: "Still going", loopType: .goalBased,
          goal: GoalSpec(summary: "Docs land", predicate: "test -f docs/out.md"),
          state: .running),
      ])
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in started.withValue { $0.append(node) } })

    await store.ensureUnattendedSessions()

    #expect(started.value.map(\.title) == ["Still going"])
  }

  @Test
  func theSessionPromptCarriesBothTheGoalAndItsPredicate() throws {
    // The session and the daemon have to be working to the same definition of done.
    let node = LoopNode(
      title: "Green build", loopType: .goalBased,
      goal: GoalSpec(summary: "CI passes", predicate: "make test"))

    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("CI passes"))
    #expect(prompt.contains("make test"))
  }

  @Test
  func theSessionPromptCarriesTheMeasurementMethod() throws {
    // The metric is a method the loop is handed, not just a score the daemon keeps: a
    // loop that doesn't know how it's measured can't steer toward improving. The same
    // command is still sampled daemon-side, so the recorded numbers never come from the
    // loop's self-report.
    let node = LoopNode(
      title: "Lint", loopType: .goalBased,
      goal: GoalSpec(
        summary: "lint is clean", metricCommand: "swiftlint | wc -l",
        metricDirection: .minimize))

    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("swiftlint | wc -l"))
    #expect(prompt.contains("lower is better"))
    #expect(prompt.contains("run it as you work"))

    // No metric, no measurement sentence — the base prompt is the directive and the
    // condition, and nothing else.
    let bare = LoopNode(
      title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "docs read clearly"))
    #expect(bare.sessionPrompt == "/goal docs read clearly")
  }

  @Test
  func aGoalOpensWithTheBackendsOwnStopCondition() throws {
    // Prose asks; the directive binds. `/goal <condition>` installs a check the session
    // cannot finish past, which is the whole contract of the type — so it leads the
    // prompt, exactly as `/loop` leads a time-based one. Every backend graphcode drives
    // has the command, so every backend gets it.
    for backend in CLISessionBackendKind.allCases {
      let node = LoopNode(
        title: "Green build", loopType: .goalBased,
        goal: GoalSpec(summary: "CI passes", predicate: "make test"), backend: backend)
      let prompt = try #require(node.sessionPrompt)
      #expect(prompt.hasPrefix("/goal CI passes"))
      #expect(prompt.contains("make test"))
      #expect(!prompt.contains("Work toward this goal"))
    }
  }

  @Test
  func aBackendWithoutTheCommandStillGetsAWorkableGoal() {
    // The prose prompt is not dead code, it is what the next backend opens with until
    // someone reads `/goal` off its real CLI. A directive typed at an agent that has no
    // such command is echoed as text and arms nothing, so `nil` has to keep working.
    let spec = GoalSpec(summary: "CI passes", predicate: "make test")
    #expect(
      spec.sessionPrompt().hasPrefix("Work toward this goal until it is met: CI passes"))
    #expect(spec.sessionPrompt().contains("make test"))
  }

  @Test
  func aGoalThatOpensWithASubcommandIsNotReadAsOne() throws {
    // `/goal clear` clears the session's goal on both backends that have the command, so
    // a goal phrased "clear the lint backlog" would arm nothing and look like it had.
    let node = LoopNode(
      title: "Lint", loopType: .goalBased,
      goal: GoalSpec(summary: "clear the lint backlog"))
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt == "/goal Done when: clear the lint backlog")

    // Only the leading word is the hazard — one in the middle is ordinary English.
    let inner = LoopNode(
      title: "Lint", loopType: .goalBased,
      goal: GoalSpec(summary: "the lint backlog is clear"))
    #expect(inner.sessionPrompt == "/goal the lint backlog is clear")
  }

  @Test
  func aTurnBasedNodeOpensWithItsCheck() throws {
    // The check used to reach nothing: required at creation, then left in the graph as
    // metadata while the session opened knowing neither the criterion nor that it was a
    // loop. Now it travels with it.
    let node = LoopNode(title: "Research", checkDescription: "Is the argument sound?")
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("Is the argument sound?"))
    // And it asks for a pause, not a summary — the hand-off this type names is the check,
    // and a session that runs to completion has already made the decisions it gated.
    #expect(prompt.contains("stopping after each one"))
  }

  @Test
  func aTurnBasedNodeStillDoesNotStartItself() {
    // Carrying a prompt is not the same as running unattended. A person opening it is
    // what should begin it — that is the entire point of the type.
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    #expect(!node.runsUnattended)
  }

  @Test
  func aCompositeNodeStillOpensBare() {
    // A composite is a graph, not a session; its sub-graph's loops carry the prompts.
    #expect(LoopNode(title: "Pipeline", loopType: .composite).sessionPrompt == nil)
  }
}
