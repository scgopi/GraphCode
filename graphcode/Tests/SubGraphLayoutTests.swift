import CoreGraphics
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// A folder canvas's composites drawn open (docs/06-ux-terminals.md#graph-canvas). The
/// counterpart to `GraphOverviewTests.aCompositeIsOneCardAndItsSubGraphIsNotExpanded`:
/// what the Graph view deliberately collapses is what a folder's own canvas expands.
@Suite
struct SubGraphLayoutTests {
  private static let project = ProjectRef(path: "/tmp/project", name: "project")
  private static let cardPosition = CGPoint(x: 160, y: 140)

  private func composite(
    _ title: String, holding nodes: [LoopNode], edges: [LoopEdge] = []
  ) -> LoopNode {
    LoopNode(
      title: title, loopType: .proactive,
      subGraph: LoopGraph(
        project: Self.project, nodes: IdentifiedArrayOf(uniqueElements: nodes),
        edges: IdentifiedArrayOf(uniqueElements: edges)))
  }

  @Test
  func aCompositesLoopsAreStackedUnderTheCardThatOwnsThem() {
    let inner = LoopNode(title: "explore", checkDescription: "?")
    let parent = composite("pipeline", holding: [inner])
    let layout = SubGraphLayout(
      nodes: [parent], positions: [parent.id: Self.cardPosition])

    #expect(layout.placements.map(\.node.title) == ["explore"])
    let chip = layout.placements[0]
    #expect(chip.depth == 1)
    // Below the card, and clear of its bottom edge.
    #expect(chip.position.y > Self.cardPosition.y + 45)
    // And tethered to the card, not floating.
    #expect(
      layout.links.contains {
        $0.kind == .containment && $0.from == Self.cardPosition && $0.to == chip.position
      })
  }

  @Test
  func aCompositeInsideACompositePointsAtItsOwnParent() {
    let deeper = LoopNode(title: "judge", checkDescription: "?")
    let nested = composite("fan-out", holding: [deeper])
    let parent = composite("pipeline", holding: [nested])
    let layout = SubGraphLayout(
      nodes: [parent], positions: [parent.id: Self.cardPosition])

    let nestedChip = layout.placements.first { $0.node.title == "fan-out" }
    let deepChip = layout.placements.first { $0.node.title == "judge" }
    #expect(nestedChip?.depth == 1)
    #expect(deepChip?.depth == 2)
    // Depth steps right, so nesting reads off the left edge.
    #expect((deepChip?.position.x ?? 0) > (nestedChip?.position.x ?? 0))
    // The containment line goes to the chip that holds it, not to the top-level card.
    #expect(
      layout.links.contains {
        $0.kind == .containment && $0.from == nestedChip?.position
          && $0.to == deepChip?.position
      })
  }

  @Test
  func aSubGraphsOwnEdgesAreDrawnBetweenItsChips() {
    let first = LoopNode(title: "explore", checkDescription: "?")
    let second = LoopNode(title: "judge", checkDescription: "?")
    let parent = composite(
      "pipeline", holding: [first, second],
      edges: [LoopEdge(from: first.id, to: second.id, spec: EdgeSpec())])
    let layout = SubGraphLayout(
      nodes: [parent], positions: [parent.id: Self.cardPosition])

    let edges = layout.links.filter {
      if case .edge = $0.kind { return true }
      return false
    }
    #expect(edges.count == 1)
  }

  @Test
  func aCompositeTooBigForTheSpaceUnderItsCardSaysWhatItIsHiding() {
    // The grid's row pitch is fixed, so the room under a card is finite. Drawing all
    // twelve would collide with the row below; dropping them silently would be worse.
    let many = (0..<12).map { LoopNode(title: "loop-\($0)", checkDescription: "?") }
    let parent = composite("fan-out", holding: many)
    let layout = SubGraphLayout(
      nodes: [parent], positions: [parent.id: Self.cardPosition])

    #expect(layout.placements.count == 3)
    #expect(layout.overflows.count == 1)
    #expect(layout.overflows[0].hidden == 9)
    #expect(layout.placements.count + layout.overflows[0].hidden == 12)
    // The overflow chip takes the slot after the last real one, not on top of it.
    #expect(layout.overflows[0].position.y > (layout.placements.map(\.position.y).max() ?? 0))
  }

  @Test
  func anEdgeIntoAHiddenChipIsNotDrawnAsALineToNowhere() {
    let many = (0..<12).map { LoopNode(title: "loop-\($0)", checkDescription: "?") }
    let parent = composite(
      "fan-out", holding: many,
      // Last to first: the `to` end is visible, the `from` end is hidden by overflow.
      edges: [LoopEdge(from: many[11].id, to: many[0].id, spec: EdgeSpec())])
    let layout = SubGraphLayout(
      nodes: [parent], positions: [parent.id: Self.cardPosition])

    #expect(
      !layout.links.contains {
        if case .edge = $0.kind { return true }
        return false
      })
  }

  @Test
  func aPlainLoopContributesNothing() {
    let plain = LoopNode(title: "review", checkDescription: "?")
    // A composite with an empty sub-graph is also nothing to draw — no chips, and no
    // stray containment line to an empty stack.
    let emptyComposite = composite("not started", holding: [])
    let layout = SubGraphLayout(
      nodes: [plain, emptyComposite],
      positions: [plain.id: Self.cardPosition, emptyComposite.id: CGPoint(x: 420, y: 140)])

    #expect(layout.isEmpty)
    #expect(layout.links.isEmpty)
    #expect(layout.overflows.isEmpty)
  }

  @Test
  func aCompositeWhoseCardHasNoPositionYetIsSkipped() {
    // Positions arrive from the canvas one broadcast later than the node itself can.
    let parent = composite("pipeline", holding: [LoopNode(title: "x", checkDescription: "?")])
    #expect(SubGraphLayout(nodes: [parent], positions: [:]).isEmpty)
  }
}
