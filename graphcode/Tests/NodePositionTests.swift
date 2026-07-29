import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Where a freshly synced loop lands on the canvas.
///
/// The bug this pins is nastier than it sounds: two cards at the *same* point don't look
/// like a layout problem, they look like the graph lost its nodes. A project with four
/// loops rendered as one visible card with three hidden exactly underneath it.
@Suite
struct NodePositionTests {
  private func node(_ title: String) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, goal: GoalSpec(summary: "go"))
  }

  @Test
  func everyLoopGetsASlotOfItsOwn() {
    var taken: Set<CGPoint> = []
    for _ in 0..<7 {
      let position = ProjectFeature.nextFreePosition(avoiding: taken)
      #expect(!taken.contains(position))
      taken.insert(position)
    }
    #expect(taken.count == 7)
  }

  @Test
  func aFreedSlotIsReusedRatherThanCollidedWith() {
    // Deleting a loop frees its position. The next node should take *that* slot back,
    // not land on one still in use.
    let first = ProjectFeature.gridPosition(0)
    let second = ProjectFeature.gridPosition(1)
    let third = ProjectFeature.gridPosition(2)

    // Everything except the middle one is occupied.
    let reused = ProjectFeature.nextFreePosition(avoiding: [first, third])
    #expect(reused == second)
  }

  @Test
  func deletingThenAddingDoesNotStackCardsOnTopOfEachOther() async {
    // The reported failure, end to end: create three loops, delete one, create another,
    // and every card must still be somewhere different. Indexing by `count` put the new
    // one exactly on an existing card.
    let project = ProjectRef(path: "/tmp/p", name: "p")
    let store = await TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: project))
    ) {
      ProjectFeature()
    } withDependencies: {
      // Deleting a loop tells the daemon about it. This test is only about where cards
      // land, so the socket is stubbed rather than reached for.
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    let loopA = node("Greeter 1")
    let loopB = node("Greeter 2")
    let loopC = node("Greeter 3")
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: project, nodes: [loopA, loopB, loopC]))))
    // `b` is deleted, and the daemon broadcasts the smaller graph.
    await store.send(.deleteNodeRequested(loopB.id))
    await store.send(.deleteNodeConfirmed)
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: project, nodes: [loopA, loopC]))))
    // A fourth loop arrives — the moment the old code collided.
    let loopD = node("Greeter 4")
    await store.send(
      .daemonEvent(.graphChanged(LoopGraph(project: project, nodes: [loopA, loopC, loopD]))))

    let positions = [loopA, loopC, loopD].compactMap { store.state.nodePositions[$0.id] }
    #expect(positions.count == 3)
    #expect(Set(positions).count == 3)
  }
}
