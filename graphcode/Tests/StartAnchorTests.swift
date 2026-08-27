import Foundation
import GraphcodeKit
import Testing

/// `LoopGraph.startAnchors` decides which loops the canvas tethers to its start marker
/// (docs/06-ux-terminals.md#graph-canvas). The property the marker is there to provide
/// is "every loop descends from start" — so what these check is that no shape of graph
/// leaves a node floating, and that the tethers stop at entry points instead of raining
/// down on every card.
@Suite
struct StartAnchorTests {
  private static let project = ProjectRef(path: "/tmp/anchors", name: "anchors")

  private func graph(nodes: [LoopNode], edges: [LoopEdge]) -> LoopGraph {
    LoopGraph(
      project: Self.project,
      nodes: .init(uniqueElements: nodes),
      edges: .init(uniqueElements: edges))
  }

  private func node(_ title: String) -> LoopNode {
    LoopNode(title: title, checkDescription: "done?")
  }

  @Test
  func aLooseNodeIsItsOwnEntryPoint() {
    let alone = node("Alone")
    #expect(graph(nodes: [alone], edges: []).startAnchors == [alone.id])
  }

  @Test
  func aChainIsAnchoredOnlyAtItsHead() {
    let first = node("First")
    let middle = node("Middle")
    let last = node("Last")
    let chain = graph(
      nodes: [first, middle, last],
      edges: [
        LoopEdge(from: first.id, to: middle.id),
        LoopEdge(from: middle.id, to: last.id),
      ])
    #expect(chain.startAnchors == [first.id])
  }

  @Test
  func everyUnrelatedChainGetsItsOwnTether() {
    let firstHead = node("First head")
    let firstTail = node("First tail")
    let secondHead = node("Second head")
    let split = graph(
      nodes: [firstHead, firstTail, secondHead],
      edges: [LoopEdge(from: firstHead.id, to: firstTail.id)])
    #expect(split.startAnchors == [firstHead.id, secondHead.id])
  }

  /// The shape with no natural head. Without the fallback the whole ring would hang off
  /// nothing, which is exactly the disconnected canvas the marker exists to prevent.
  @Test
  func aClosedCycleIsAnchoredAtItsFirstNodeRatherThanNotAtAll() {
    let first = node("First")
    let second = node("Second")
    let ring = graph(
      nodes: [first, second],
      edges: [
        LoopEdge(from: first.id, to: second.id),
        LoopEdge(from: second.id, to: first.id),
      ])
    #expect(ring.startAnchors == [first.id])
  }

  /// A cycle hanging off a chain is already reachable, so it must not pick up a tether
  /// of its own — the fallback is for components with no way in, not for every loop.
  @Test
  func aCycleReachableFromAnEntryPointIsNotAnchoredSeparately() {
    let head = node("Head")
    let first = node("First")
    let second = node("Second")
    let lasso = graph(
      nodes: [head, first, second],
      edges: [
        LoopEdge(from: head.id, to: first.id),
        LoopEdge(from: first.id, to: second.id),
        LoopEdge(from: second.id, to: first.id),
      ])
    #expect(lasso.startAnchors == [head.id])
  }

  @Test
  func anEmptyGraphHasNothingToAnchor() {
    #expect(graph(nodes: [], edges: []).startAnchors.isEmpty)
  }

  @Test
  func aLooseNodeIsNotAnEntryPoint() {
    // By the "nothing hands off to it" rule a loose loop is a root, and treating it as
    // one is how ten unwired loops became a ten-line starburst out of a single dot. It
    // is still a `startAnchor` — the canvas has to be able to find it — but it is not a
    // beginning, and the card says so instead of drawing a port.
    let alone = node("Alone")
    let graph = graph(nodes: [alone], edges: [])

    #expect(graph.startAnchors == [alone.id])
    #expect(graph.entryPoints.isEmpty)
    #expect(graph.unwiredNodeIDs == [alone.id])
    #expect(graph.cycleOnlyNodeIDs.isEmpty)
  }

  @Test
  func aRealRootIsAnEntryPointAndItsDownstreamIsNot() {
    let first = node("First")
    let second = node("Second")
    let chain = graph(
      nodes: [first, second], edges: [LoopEdge(from: first.id, to: second.id)])

    #expect(chain.entryPoints == [first.id])
    #expect(chain.unwiredNodeIDs.isEmpty)
    #expect(chain.cycleOnlyNodeIDs.isEmpty)
  }

  @Test
  func aClosedCycleHasNoEntryPointAtAll() {
    // `startAnchors` still picks one so the graph has somewhere to be read from. The
    // card must not repeat that pick as a fact: nothing in the graph makes either loop
    // the beginning, and a port on one of them would be a coin toss drawn as structure.
    let maker = node("Maker")
    let reviewer = node("Reviewer")
    let ring = graph(
      nodes: [maker, reviewer],
      edges: [
        LoopEdge(from: maker.id, to: reviewer.id),
        LoopEdge(from: reviewer.id, to: maker.id),
      ])

    #expect(ring.entryPoints.isEmpty)
    #expect(ring.cycleOnlyNodeIDs == [maker.id, reviewer.id])
    // And both still appear, which is what the anchor is for.
    #expect(ring.startAnchors == [maker.id])
  }

  @Test
  func aCycleHangingOffARootKeepsTheRootAsItsEntryPoint() {
    // The shape that matters in practice: a maker/reviewer loop fed by an explorer.
    let head = node("Head")
    let maker = node("Maker")
    let reviewer = node("Reviewer")
    let lasso = graph(
      nodes: [head, maker, reviewer],
      edges: [
        LoopEdge(from: head.id, to: maker.id),
        LoopEdge(from: maker.id, to: reviewer.id),
        LoopEdge(from: reviewer.id, to: maker.id),
      ])

    #expect(lasso.entryPoints == [head.id])
    #expect(lasso.cycleOnlyNodeIDs.isEmpty)
  }

  /// A sketch is not a graph beginning. Edgeless by construction, it would otherwise
  /// claim an entry port the moment it was created — re-creating the starburst the
  /// entry-point work removed.
  @Test
  func aSketchNeverClaimsAnEntryPort() {
    let sketch = LoopNode(title: "Poke around", loopType: .sketch)
    let worker = node("Worker")
    let mixed = graph(nodes: [sketch, worker], edges: [])
    #expect(mixed.startAnchors == [worker.id])
    #expect(graph(nodes: [sketch], edges: []).startAnchors.isEmpty)
  }

  /// No entry port is not the same as no row: the sidebar lists untargeted sketches
  /// after the anchored roots, or a fresh sketch simply doesn't exist anywhere but the
  /// canvas. A sketch something points at lists as that node's child instead.
  @Test
  func theSidebarStillRowsAnUntargetedSketch() {
    let sketch = LoopNode(title: "Poke around", loopType: .sketch)
    let worker = node("Worker")
    let mixed = graph(nodes: [sketch, worker], edges: [])
    #expect(mixed.sidebarRoots == [worker.id, sketch.id])
    #expect(graph(nodes: [sketch], edges: []).sidebarRoots == [sketch.id])

    let child = graph(
      nodes: [worker, sketch], edges: [LoopEdge(from: worker.id, to: sketch.id)])
    #expect(child.sidebarRoots == [worker.id])
  }

  // MARK: - Only a handoff is a sequencing edge (#194)

  /// **The orchestrator shape, and the bug it exposed.** A parent hands off to each child
  /// and each child messages its result back — the pattern graphcode itself teaches, since
  /// a child's memory is seeded at birth with the `node send <parent>` route.
  ///
  /// Counting the `message` return edges as sequencing made the parent "targeted", so the
  /// whole component had no entry point and the canvas drew `cycle · no entry point` over
  /// a graph with an obvious root. `EdgeKind.blocksTarget` had said the right rule since
  /// the edge specs went in — "also what cycle traversal follows" — and this was the one
  /// place that never asked it.
  @Test
  func aReportBackMessageDoesNotMakeTheParentTargeted() {
    let parent = node("Orchestrator")
    let children = (1...3).map { node("child \($0)") }
    let wiring = children.flatMap { child in
      [
        LoopEdge(from: parent.id, to: child.id, kind: .handoff),
        LoopEdge(from: child.id, to: parent.id, kind: .message),
      ]
    }
    let subject = graph(nodes: [parent] + children, edges: wiring)

    #expect(subject.entryPoints == [parent.id])
    #expect(subject.cycleOnlyNodeIDs.isEmpty)
    #expect(subject.startAnchors == [parent.id])
  }

  /// The other half of the same rule: a genuine sequencing cycle must still be one. Two
  /// handoffs closing a ring have no entry point, and saying so is the honest answer —
  /// `startAnchors` still picks one so nothing floats free of the start marker.
  @Test
  func aRingOfHandoffsIsStillACycleWithNoEntryPoint() {
    let first = node("first")
    let second = node("second")
    let subject = graph(
      nodes: [first, second],
      edges: [
        LoopEdge(from: first.id, to: second.id, kind: .handoff),
        LoopEdge(from: second.id, to: first.id, kind: .handoff),
      ])

    #expect(subject.entryPoints.isEmpty)
    #expect(subject.cycleOnlyNodeIDs == Set([first.id, second.id]))
    #expect(subject.startAnchors.count == 1)
  }

  /// A consequence worth pinning rather than discovering. Neither kind gates its target —
  /// a `message` peer runs concurrently and a `spawn` target is a template waiting on
  /// nothing — so both ends of such a pair are beginnings, and the canvas draws two entry
  /// ports. Consistent with `EdgeKind.blocksTarget`, and a visible change from when every
  /// edge counted.
  @Test
  func aPairWiredOnlyByANonSequencingEdgeHasTwoBeginnings() {
    for kind in [EdgeKind.message, .spawn] {
      let from = node("from")
      let to = node("to")
      let subject = graph(
        nodes: [from, to], edges: [LoopEdge(from: from.id, to: to.id, kind: kind)])

      #expect(subject.entryPoints == [from.id, to.id], "\(kind)")
      #expect(subject.cycleOnlyNodeIDs.isEmpty, "\(kind)")
    }
  }

  /// And the one place that must keep counting every kind. A loop reachable only by a
  /// `message` is wired to something — calling it loose would put it in the starburst of
  /// accidents that `unwiredNodeIDs` exists to separate out.
  @Test
  func aNodeWiredOnlyByAMessageIsNotLoose() {
    let from = node("from")
    let to = node("to")
    let subject = graph(
      nodes: [from, to], edges: [LoopEdge(from: from.id, to: to.id, kind: .message)])

    #expect(subject.unwiredNodeIDs.isEmpty)
  }
}
