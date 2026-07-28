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
}
