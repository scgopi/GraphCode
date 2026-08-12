import ComposableArchitecture
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// Where a folder canvas's loops land.
///
/// The bug this started from is nastier than it sounds: two cards at the *same* point don't
/// look like a layout problem, they look like the graph lost its nodes. A project with four
/// loops rendered as one visible card with three hidden exactly underneath it.
///
/// What the canvas does now is the Graph view's own layout (`LaneLayout`), so the rest of
/// these are about the thing that made the two views disagree: the old grid handed out
/// slots in arrival order and never read an edge, so a wired-up graph looked exactly like a
/// scatter of unrelated loops.
@Suite
struct NodePositionTests {
  private static let project = ProjectRef(path: "/tmp/p", name: "p")

  private func node(_ title: String) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, goal: GoalSpec(summary: "go"))
  }

  private func graph(nodes: [LoopNode], edges: [LoopEdge] = []) -> LoopGraph {
    LoopGraph(
      project: Self.project, nodes: IdentifiedArrayOf(uniqueElements: nodes),
      edges: IdentifiedArrayOf(uniqueElements: edges))
  }

  @Test
  func everyLoopGetsAPointOfItsOwn() {
    let nodes = (0..<7).map { node("loop-\($0)") }
    let placed = LaneLayout.positions(
      forCanvas: graph(
        nodes: nodes,
        edges: [
          LoopEdge(from: nodes[0].id, to: nodes[1].id),
          LoopEdge(from: nodes[1].id, to: nodes[2].id),
        ]))

    #expect(placed.count == nodes.count)
    #expect(Set(placed.values).count == nodes.count)
  }

  /// The reported bug, stated as an equality: a folder's own canvas has to place that
  /// folder's loops exactly where the Graph view places them.
  ///
  /// Not "similarly" — the same points. A project canvas is one lane of the Graph view
  /// with the other folders and the start node taken away, so the first lane's origin *is*
  /// the project canvas's origin, and any difference at all is the two views having two
  /// opinions about what the graph looks like.
  @Test
  func aFoldersCanvasPlacesCardsExactlyWhereTheGraphViewDoes() {
    let root = node("root")
    let middle = node("middle")
    let leaf = node("leaf")
    let secondRoot = node("second root")
    let loose = node("loose")
    let spun = node("spun")
    let counterSpun = node("counter-spun")
    let wired = graph(
      nodes: [leaf, loose, root, spun, middle, counterSpun, secondRoot],
      edges: [
        LoopEdge(from: root.id, to: middle.id),
        LoopEdge(from: middle.id, to: leaf.id),
        LoopEdge(from: secondRoot.id, to: leaf.id),
        // A closed cycle too: it has no beginning, so it is placed last, and "last" has to
        // mean the same thing on both canvases.
        LoopEdge(from: spun.id, to: counterSpun.id),
        LoopEdge(from: counterSpun.id, to: spun.id),
      ])

    let overview = GraphOverview(graphs: [wired])
    let lane = Dictionary(uniqueKeysWithValues: overview.loops.map { ($0.id, $0.position) })
    let canvas = ProjectFeature.State(graph: wired).nodePositions

    #expect(!lane.isEmpty)
    #expect(canvas == lane)
  }

  @Test
  func anOpenCompositeBuysTallerRowsAndNothingElse() {
    // The one deliberate departure: a composite drawn open hangs chips below its card, and
    // the Graph view — which expands nothing — leaves no room for them between rows. The
    // canvas takes a taller pitch for that, and only that: same columns, same rows, same
    // order. Anything else would be the two views disagreeing again.
    let inner = node("inner")
    let composite = LoopNode(
      title: "pipeline", loopType: .composite,
      subGraph: LoopGraph(project: Self.project, nodes: [inner]))
    let downstream = node("downstream")
    let wired = graph(
      nodes: [composite, downstream],
      edges: [LoopEdge(from: composite.id, to: downstream.id)])

    let slots = LaneLayout(graph: wired, roles: CardEntryRole.roles(in: wired)).slots
    let canvas = ProjectFeature.State(graph: wired).nodePositions
    let pitch = LaneLayout.rowHeight(for: wired)
    #expect(pitch > LaneLayout.Metrics.rowHeight)

    for (id, slot) in slots {
      #expect(
        canvas[id]
          == CGPoint(
            x: LaneLayout.Metrics.origin.x + CGFloat(slot.column) * LaneLayout.Metrics.columnWidth,
            y: LaneLayout.Metrics.origin.y + CGFloat(slot.row) * pitch))
    }
  }

  @Test
  func aChainRunsLeftToRightAlongOneRow() {
    // The reported difference between the two views: on the Graph view A → B → C is a line
    // of work; on a folder's canvas it was three cards in whatever order they synced, with
    // the hand-offs drawn behind them.
    let first = node("first")
    let second = node("second")
    let third = node("third")
    let placed = LaneLayout.positions(
      forCanvas: graph(
        nodes: [third, first, second],
        edges: [
          LoopEdge(from: first.id, to: second.id), LoopEdge(from: second.id, to: third.id),
        ]))

    #expect(placed[first.id]?.y == placed[second.id]?.y)
    #expect(placed[second.id]?.y == placed[third.id]?.y)
    #expect((placed[second.id]?.x ?? 0) > (placed[first.id]?.x ?? 0))
    #expect((placed[third.id]?.x ?? 0) > (placed[second.id]?.x ?? 0))
  }

  @Test
  func beginningsStackDownTheFirstColumn() {
    let root = node("root")
    let downstream = node("downstream")
    let loose = node("loose")
    let placed = LaneLayout.positions(
      forCanvas: graph(
        nodes: [root, downstream, loose],
        edges: [LoopEdge(from: root.id, to: downstream.id)]))

    // Both beginnings in the column the band's origin dot reaches, on rows of their own.
    #expect(placed[root.id]?.x == LaneLayout.Metrics.origin.x)
    #expect(placed[loose.id]?.x == LaneLayout.Metrics.origin.x)
    #expect(placed[root.id]?.y != placed[loose.id]?.y)
    #expect((placed[downstream.id]?.x ?? 0) > (placed[root.id]?.x ?? 0))
  }

  @Test
  @MainActor
  func wiringTwoLoopsTogetherReflowsTheCanvas() async throws {
    // The point of deriving positions rather than storing them: drawing an edge has to
    // change what the canvas looks like, or the graph is a picture of the order things
    // arrived in.
    let upstream = node("upstream")
    let downstream = node("downstream")
    let loose = graph(nodes: [upstream, downstream])
    let store = TestStore(initialState: ProjectFeature.State(graph: loose)) {
      ProjectFeature()
    }
    store.exhaustivity = .off

    await store.send(.daemonEvent(.graphChanged(loose)))
    // Two loose loops: both beginnings, stacked down the first column.
    #expect(
      store.state.nodePositions[upstream.id]?.x == store.state.nodePositions[downstream.id]?.x)

    let wired = graph(
      nodes: [upstream, downstream],
      edges: [LoopEdge(from: upstream.id, to: downstream.id)])
    await store.send(.daemonEvent(.graphChanged(wired)))

    let from = try #require(store.state.nodePositions[upstream.id])
    let to = try #require(store.state.nodePositions[downstream.id])
    #expect(to.x > from.x)
    #expect(to.y == from.y)
  }

  @Test
  @MainActor
  func aCompositesInsidesArePlacedForTheCanvasThatDrillsIntoThem() async {
    // Opening a composite swaps the canvas over to its sub-graph, so those loops need
    // positions of their own — without them every card of a drilled-in canvas draws at the
    // same unplaced point.
    let inner = node("inner")
    let composite = LoopNode(
      title: "pipeline", loopType: .composite,
      subGraph: LoopGraph(project: Self.project, nodes: [inner]))
    let store = TestStore(
      initialState: ProjectFeature.State(graph: graph(nodes: [composite]))
    ) {
      ProjectFeature()
    }
    store.exhaustivity = .off

    #expect(store.state.nodePositions[inner.id] != nil)

    await store.send(.daemonEvent(.graphChanged(graph(nodes: [composite]))))
    #expect(store.state.nodePositions[inner.id] != nil)
  }

  @Test
  @MainActor
  func deletingThenAddingDoesNotStackCardsOnTopOfEachOther() async {
    // The reported failure, end to end: create three loops, delete one, create another,
    // and every card must still be somewhere different. Indexing by `count` put the new
    // one exactly on an existing card.
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.project))
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
    await store.send(.daemonEvent(.graphChanged(graph(nodes: [loopA, loopB, loopC]))))
    // `b` is deleted, and the daemon broadcasts the smaller graph.
    await store.send(.deleteNodeRequested(loopB.id))
    await store.send(.deleteNodeConfirmed)
    await store.send(.daemonEvent(.graphChanged(graph(nodes: [loopA, loopC]))))
    // A fourth loop arrives — the moment the old code collided.
    let loopD = node("Greeter 4")
    await store.send(.daemonEvent(.graphChanged(graph(nodes: [loopA, loopC, loopD]))))

    let positions = [loopA, loopC, loopD].compactMap { store.state.nodePositions[$0.id] }
    #expect(positions.count == 3)
    #expect(Set(positions).count == 3)
    // And the loop that went away takes its point with it.
    #expect(store.state.nodePositions[loopB.id] == nil)
  }
}
