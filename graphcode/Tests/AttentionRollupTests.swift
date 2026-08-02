import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The orchestrator's needs-attention rollup
/// (docs/05-orchestrator.md#monitoring-surface).
///
/// The rollup's value is entirely in what it *leaves out*. A list that reports every
/// blocked node buries the two real problems under fifteen normal ones, at which point a
/// human stops reading it — which is the exact failure this surface exists to prevent.
@Suite
struct AttentionRollupTests {
  private func graph(
    _ name: String = "proj", nodes: [LoopNode], edges: [LoopEdge] = []
  ) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/\(name)", name: name),
      nodes: IdentifiedArray(uniqueElements: nodes),
      edges: IdentifiedArray(uniqueElements: edges))
  }

  @Test
  func aHealthyGraphAsksForNothing() {
    let rollup = AttentionRollup.fullRollup(across: [
      graph(nodes: [
        LoopNode(title: "Running", state: .running),
        LoopNode(title: "Done", state: .succeeded),
        LoopNode(title: "Waiting to start", state: .idle),
      ])
    ])

    #expect(rollup.isEmpty)
  }

  @Test
  func failedStalledAndAwaitingInputAllSurface() {
    let rollup = AttentionRollup.fullRollup(across: [
      graph(nodes: [
        LoopNode(title: "Broke", state: .failed),
        LoopNode(title: "Hung", state: .stalled),
        LoopNode(title: "Asking", state: .awaitingInput),
      ])
    ])

    #expect(rollup.map(\.reason) == [.failed, .stalled, .awaitingInput])
  }

  @Test
  func aStoppedLoopIsNotSomethingToActOn() {
    // A human turned it off. Telling them it needs their attention is telling them
    // about their own decision.
    let rollup = AttentionRollup.fullRollup(across: [
      graph(nodes: [LoopNode(title: "Turned off", state: .stopped)])
    ])

    #expect(rollup.isEmpty)
  }

  @Test
  func aNodeBlockedOnWorkThatIsStillRunningIsNotReported() {
    // This is the ordinary, healthy case — it's what "blocked" means most of the time,
    // and reporting it would be reporting the graph working correctly.
    let upstream = LoopNode(title: "Upstream", state: .running)
    let downstream = LoopNode(title: "Downstream", state: .blocked)

    let rollup = AttentionRollup.fullRollup(across: [
      graph(
        nodes: [upstream, downstream],
        edges: [LoopEdge(from: upstream.id, to: downstream.id)])
    ])

    #expect(rollup.isEmpty)
  }

  @Test
  func aNodeBlockedOnWorkThatCanNeverArriveIsStranded() {
    // The upstream resolved without firing this edge — an `.onSuccess` edge whose
    // source failed. Nothing will ever unblock the target, so it needs a human.
    let upstream = LoopNode(title: "Upstream", state: .failed)
    let downstream = LoopNode(title: "Downstream", state: .blocked)

    let rollup = AttentionRollup.fullRollup(across: [
      graph(
        nodes: [upstream, downstream],
        edges: [
          LoopEdge(from: upstream.id, to: downstream.id, condition: .onSuccess, fireCount: 0)
        ])
    ])

    #expect(rollup.map(\.reason) == [.failed, .blocked])
    #expect(rollup.last?.nodeTitle == "Downstream")
  }

  @Test
  func worstFirst() {
    // A failure outranks a question, which outranks a stuck wait — so the top of the
    // list is always the thing most worth doing next.
    let rollup = AttentionRollup.fullRollup(across: [
      graph(nodes: [
        LoopNode(title: "Asking", state: .awaitingInput),
        LoopNode(title: "Hung", state: .stalled),
        LoopNode(title: "Broke", state: .failed),
      ])
    ])

    #expect(rollup.map(\.nodeTitle) == ["Broke", "Hung", "Asking"])
  }

  @Test
  func oldestFirstWithinAReason() {
    // Between two equally-bad problems, the one that's been ignored longest wins.
    let old = LoopNode(
      title: "Old", state: .failed, createdAt: Date(timeIntervalSince1970: 0))
    let recent = LoopNode(
      title: "Recent", state: .failed, createdAt: Date(timeIntervalSince1970: 9999))

    let rollup = AttentionRollup.items(across: [graph(nodes: [recent, old])])

    #expect(rollup.map(\.nodeTitle) == ["Old", "Recent"])
  }

  @Test
  func theQueueIsOneListAcrossEveryOpenProject() {
    // docs/05 asks for this "regardless of which LoopGraph they belong to" — a human
    // with several projects open has one attention queue, not one per project.
    let rollup = AttentionRollup.fullRollup(across: [
      graph("alpha", nodes: [LoopNode(title: "Asking", state: .awaitingInput)]),
      graph("beta", nodes: [LoopNode(title: "Broke", state: .failed)]),
    ])

    #expect(rollup.map(\.nodeTitle) == ["Broke", "Asking"])
    #expect(rollup.first?.projectName == "beta")
  }

  @Test
  func aGraphRollsUpToItsWorstNode() {
    // So a human can tell whether a project needs them without opening its canvas.
    #expect(
      graph(nodes: [
        LoopNode(title: "a", state: .running), LoopNode(title: "b", state: .failed),
      ]).aggregateState == .failed)
    #expect(
      graph(nodes: [
        LoopNode(title: "a", state: .running), LoopNode(title: "b", state: .succeeded),
      ]).aggregateState == .running)
    #expect(
      graph(nodes: [
        LoopNode(title: "a", state: .succeeded), LoopNode(title: "b", state: .succeeded),
      ]).aggregateState == .succeeded)
  }

  @Test
  func anEmptyGraphIsIdleNotSucceeded() {
    // A project with no loops hasn't finished anything; calling it succeeded would put
    // a green tick on an empty canvas.
    #expect(graph(nodes: []).aggregateState == .idle)
  }

  @Test
  func everyStateThatWantsAHumanIsOneTheRollupCanSurface() {
    // `LoopState.wantsHuman` decides whether a card offers an action instead of a
    // progress bar; this rollup decides what the attention rail and the sidebar list.
    // If the two ever disagree, a card asks you a question that nothing on the window
    // chrome can lead you to — you'd have to pan the canvas to find it, which is the
    // whole failure this redesign is removing.
    for state in LoopState.allCases where state.wantsHuman {
      let upstream = LoopNode(title: "Upstream", state: .failed)
      let node = LoopNode(title: "Wants a human", state: state)
      let rollup = AttentionRollup.fullRollup(across: [
        graph(
          nodes: [upstream, node],
          edges: [LoopEdge(from: upstream.id, to: node.id, condition: .onSuccess, fireCount: 0)])
      ])

      #expect(
        rollup.contains { $0.nodeID == node.id },
        "\(state) wants a human but the rollup never mentions it")
    }
  }

  @Test
  func aStateTheRollupIgnoresNeverClaimsToNeedAnswering() {
    // The converse, and the weaker half on purpose: `failed` and `stalled` are in the
    // rollup without being `wantsHuman`, because they are over — there is nothing to
    // answer, only something to read.
    for state in LoopState.allCases where state != .blocked {
      // On its own, with nothing upstream of it — the only thing being asked here is
      // what the state alone is worth reporting. `.blocked` is excluded because it is
      // the one state whose answer needs the graph: see the stranded cases above.
      let node = LoopNode(title: "n", state: state)
      guard AttentionRollup.fullRollup(across: [graph(nodes: [node])]).isEmpty else {
        continue
      }

      #expect(!state.wantsHuman, "\(state) asks for an answer nothing will ever request")
    }
  }
}
