import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// Token budgets on goals — docs/08-quality-and-token-budgets.md's budget as an
/// enforced bound rather than a reviewed number. Driven through `evaluateGoal` directly
/// for the same reason `GoalBasedLoopTests` is: the poller is a sleep loop around
/// exactly this call.
@Suite
struct TokenBudgetTests {
  private func budgetGraph(budget: Int? = 100, state: LoopState = .running) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/budget", name: "budget"),
      nodes: [
        LoopNode(
          title: "Sweep", loopType: .goalBased,
          goal: GoalSpec(summary: "the sweep finishes", tokenBudget: budget),
          state: state)
      ])
  }

  @Test
  func blowingTheBudgetStallsTheLoopAndAsksItsSessionToStop() async {
    let delivered = LockIsolated<[String]>([])
    let remembered = LockIsolated<[String]>([])
    let graph = budgetGraph()
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadUsage: { _, _ in UsageSample(inputTokens: 80, outputTokens: 30) },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })

    await store.evaluateGoal(graph.nodes[0].id)

    #expect(await store.graph.nodes[0].state == .stalled)
    #expect(delivered.value.count == 1)
    #expect(delivered.value[0].contains("110 of its 100-token budget"))
    #expect(remembered.value.contains { $0.contains("budget exhausted: 110 of 100") })
  }

  @Test
  func aBlownBudgetFiresDownstreamEdgesAsAFailure() async {
    // Same reasoning as a stall: everything waiting on this loop must not sit blocked
    // forever because the money ran out.
    let graph = budgetGraph()
    let store = GraphStore(
      graph: graph, onReadUsage: { _, _ in UsageSample(inputTokens: 200) })
    let goalID = graph.nodes[0].id
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Escalate", loopType: .turnBased, checkDescription: "?",
          firstInstruction: "Escalate")))
    let escalateID = await store.graph.nodes[1].id
    await store.handle(
      .createEdge(from: goalID, to: escalateID, spec: EdgeSpec(condition: .onFailure)))

    await store.evaluateGoal(goalID)

    let updated = await store.graph
    #expect(updated.edges[0].fired == true)
    #expect(updated.nodes[id: escalateID]?.state == .idle)
  }

  @Test
  func usageUnderTheBudgetKeepsTheLoopRunningAndIsRecordedOnTheNode() async {
    let graph = budgetGraph()
    let store = GraphStore(
      graph: graph, onReadUsage: { _, _ in UsageSample(inputTokens: 40, outputTokens: 10) })

    await store.evaluateGoal(graph.nodes[0].id)

    let node = await store.graph.nodes[0]
    #expect(node.state == .running)
    #expect(node.usage?.totalTokens == 50)
  }

  @Test
  func unreportedUsageNeverExhaustsABudget() async {
    // The budget shares `UsageSample`'s honesty rule: a backend that reports nothing
    // spends nothing the daemon can act on — nil is "not reported", never zero and
    // never infinity.
    let graph = budgetGraph()
    let store = GraphStore(graph: graph, onReadUsage: { _, _ in nil })

    await store.evaluateGoal(graph.nodes[0].id)

    #expect(await store.graph.nodes[0].state == .running)
  }

  @Test
  func aLoopMayNotChangeItsOwnBudget() async {
    let remembered = LockIsolated<[String]>([])
    let graph = budgetGraph()
    let store = GraphStore(
      graph: graph,
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })
    let nodeID = graph.nodes[0].id

    await store.handle(
      .updateNode(nodeID, update: NodeUpdate(tokenBudget: 999_999, updatedBy: nodeID)))

    #expect(await store.graph.nodes[0].goal?.tokenBudget == 100)
    #expect(remembered.value.contains { $0.contains("update refused") })
  }

  @Test
  func aHumanCanRaiseOrClearTheBudget() async {
    let graph = budgetGraph()
    let store = GraphStore(graph: graph)
    let nodeID = graph.nodes[0].id

    await store.handle(.updateNode(nodeID, update: NodeUpdate(tokenBudget: 500)))
    #expect(await store.graph.nodes[0].goal?.tokenBudget == 500)

    await store.handle(.updateNode(nodeID, update: NodeUpdate(tokenBudget: 0)))
    #expect(await store.graph.nodes[0].goal?.tokenBudget == nil)
  }

  @Test
  func theSessionPromptCarriesTheBudget() throws {
    // Told for the same reason the metric is: a loop that doesn't know its budget can
    // only be surprised by it.
    let node = LoopNode(
      title: "Sweep", loopType: .goalBased,
      goal: GoalSpec(summary: "done", tokenBudget: 5000))
    let prompt = try #require(node.sessionPrompt)
    #expect(prompt.contains("Token budget: 5000"))

    let unbounded = LoopNode(
      title: "Sweep", loopType: .goalBased, goal: GoalSpec(summary: "done"))
    #expect(try #require(unbounded.sessionPrompt).contains("Token budget") == false)
  }

  @Test
  func theCLIParsesBudgetOnCreateAndUpdate() throws {
    let create = try GraphcodeCommand.parse([
      "node", "create", "/tmp/p", "--title", "Sweep", "--type", "goal",
      "--goal", "done", "--budget", "5000",
    ])
    guard case .createNode(_, let draft, _) = create else {
      Issue.record("expected createNode, got \(create)")
      return
    }
    #expect(draft.goal?.tokenBudget == 5000)

    let update = try GraphcodeCommand.parse([
      "node", "update", "/tmp/p", UUID().uuidString, "--budget", "0",
    ])
    guard case .updateNode(_, _, let nodeUpdate) = update else {
      Issue.record("expected updateNode, got \(update)")
      return
    }
    #expect(nodeUpdate.tokenBudget == 0)

    // A creation budget of zero is a contradiction, not a clear — refused.
    #expect(throws: GraphcodeCommand.ParseError.self) {
      try GraphcodeCommand.parse([
        "node", "create", "/tmp/p", "--title", "S", "--type", "goal",
        "--goal", "done", "--budget", "0",
      ])
    }
  }
}
