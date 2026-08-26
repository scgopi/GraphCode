import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Where the boxes end up. The layout is the half of the board feature that has arithmetic
/// in it, and arithmetic that can only be checked by looking at a window is arithmetic
/// nobody checks.
@Suite
struct BoardLayoutTests {

  private func board(
    _ edges: [(String, String)], direction: BoardDirection = .topDown,
    nodes: [BoardNode]? = nil
  ) -> SummaryBoard {
    let ids = nodes?.map(\.id) ?? Array(Set(edges.flatMap { [$0.0, $0.1] })).sorted()
    return SummaryBoard(
      form: .flow, direction: direction,
      nodes: nodes ?? ids.map { BoardNode(id: $0, text: $0) },
      edges: edges.map { BoardEdge(from: $0.0, to: $0.1) },
      source: "", pass: 1)
  }

  private func layer(_ layout: BoardLayout, _ id: String) -> CGFloat? {
    layout.nodes.first { $0.id == id }?.frame.minY
  }

  @Test
  func aChainDescendsOneLayerAtATime() throws {
    let layout = BoardLayout(board: board([("A", "B"), ("B", "C")]))
    let first = try #require(layer(layout, "A"))
    let second = try #require(layer(layout, "B"))
    let third = try #require(layer(layout, "C"))

    #expect(first < second)
    #expect(second < third)
  }

  /// Longest path, not shortest: a step with two prerequisites belongs *under both*, or the
  /// arrow from the deeper one runs backwards up the diagram.
  @Test
  func aJoinSitsBelowItsDeepestPrerequisite() throws {
    let layout = BoardLayout(board: board([("A", "B"), ("B", "C"), ("A", "C")]))
    let branch = try #require(layer(layout, "B"))
    let join = try #require(layer(layout, "C"))

    #expect(branch < join)
  }

  /// The commonest shape a real run has — a check that sends you back to the work. Without
  /// cycle-breaking there is no topological order at all and the layout has nothing to do.
  @Test
  func aRetryLoopStillHasLayersAndIsRoutedRound() throws {
    let layout = BoardLayout(
      board: board([("A", "B"), ("B", "C"), ("C", "B"), ("C", "D")]))

    #expect(layout.nodes.count == 4)
    let feedback = layout.edges.filter(\.isFeedback)
    #expect(feedback.map(\.edge.from) == ["C"])
    #expect(feedback.map(\.edge.to) == ["B"])
  }

  /// **The invariant a retry arrow actually has to hold.** Boxes are drawn over the arrows,
  /// so a feedback route that crosses one does not look like a mistake — the arrow simply
  /// vanishes behind it, and a diagram whose whole point is the loop appears to have none.
  /// That is precisely what the first routing did: out of the source's right side, at the
  /// same height as every other box in its row.
  @Test
  func afeedbackArrowCrossesNoBoxOnItsWayBack() {
    let layout = BoardLayout(
      board: board([
        // Two retries, each with a sibling sitting between the arrow and its lane.
        ("A", "B"), ("B", "C"), ("C", "D"), ("D", "E"), ("E", "F"),
        ("D", "G"), ("E", "H"), ("F", "B"), ("H", "D"),
      ]))
    let feedback = layout.edges.filter(\.isFeedback)
    #expect(!feedback.isEmpty)

    for edge in feedback {
      let ends: Set<String> = [edge.edge.from, edge.edge.to]
      let points = [edge.start] + edge.waypoints + [edge.end]
      for (start, end) in zip(points, points.dropFirst()) {
        for placed in layout.nodes where !ends.contains(placed.id) {
          #expect(
            !Self.segment(start, end, crosses: placed.frame),
            "\(edge.edge.from)→\(edge.edge.to) runs through \(placed.id)")
        }
      }
    }
  }

  /// Sampled rather than solved. A segment/rectangle intersection is a page of code to get
  /// right and this is a test — sixty points along a leg catches any crossing wide enough
  /// to hide a box behind.
  private static func segment(_ start: CGPoint, _ end: CGPoint, crosses rect: CGRect) -> Bool {
    let box = rect.insetBy(dx: 0.5, dy: 0.5)
    return (0...60).contains { step in
      let fraction = CGFloat(step) / 60
      return box.contains(
        CGPoint(
          x: start.x + (end.x - start.x) * fraction,
          y: start.y + (end.y - start.y) * fraction))
    }
  }

  /// Two arrows joining the same pair of boxes must not land on top of each other: drawn
  /// straight they are one line with two labels stacked on one point, and the second label
  /// is simply invisible.
  @Test
  func twoArrowsBetweenTheSamePairAreHeldApart() {
    let layout = BoardLayout(
      board: SummaryBoard(
        form: .flow,
        nodes: [BoardNode(id: "A", text: "A", shape: .decision), BoardNode(id: "B", text: "B")],
        edges: [
          BoardEdge(from: "A", to: "B", label: "yes"),
          BoardEdge(from: "A", to: "B", label: "no"),
        ], source: "", pass: 1))

    let labels = layout.edges.map(\.labelPoint)
    #expect(labels.count == 2)
    #expect(labels[0] != labels[1])
    #expect(abs(labels[0].x - labels[1].x) >= BoardLayout.parallelSpread - 0.001)
  }

  @Test
  func everythingIsDrawnInsideTheSizeItReports() {
    let layout = BoardLayout(
      board: board([("A", "B"), ("A", "C"), ("B", "D"), ("C", "D"), ("D", "A")]))

    #expect(layout.size.width > 0)
    #expect(layout.size.height > 0)
    #expect(layout.nodes.allSatisfy { $0.frame.minX >= 0 && $0.frame.minY >= 0 })
    #expect(layout.nodes.allSatisfy { $0.frame.maxX <= layout.size.width + 0.5 })
    #expect(layout.nodes.allSatisfy { $0.frame.maxY <= layout.size.height + 0.5 })
  }

  @Test
  func siblingsNeverOverlap() {
    let layout = BoardLayout(
      board: board([
        ("A", "B"), ("A", "C"), ("A", "D"), ("A", "E"),
        ("B", "F"), ("C", "F"), ("D", "G"), ("E", "G"),
      ]))

    for first in layout.nodes {
      for second in layout.nodes where first.id != second.id {
        #expect(!first.frame.insetBy(dx: 0.5, dy: 0.5).intersects(second.frame))
      }
    }
  }

  @Test
  func anLRBoardRunsAcrossRatherThanDown() throws {
    let layout = BoardLayout(board: board([("A", "B"), ("B", "C")], direction: .leftRight))
    let head = try #require(layout.nodes.first { $0.id == "A" }?.frame)
    let tail = try #require(layout.nodes.first { $0.id == "C" }?.frame)

    #expect(head.maxX <= tail.minX)
    // And the boxes keep the size their labels measured to — transposing positions must
    // not transpose the boxes themselves into tall slivers.
    #expect(head.width > head.height)
  }

  /// A diamond wastes its corners, so the same words need a bigger box inside one.
  @Test
  func aDecisionIsGivenRoomForItsCorners() {
    let plain = BoardLayout.nodeSize(BoardNode(id: "A", text: "Did it work", shape: .box))
    let diamond = BoardLayout.nodeSize(
      BoardNode(id: "A", text: "Did it work", shape: .decision))

    #expect(diamond.width > plain.width)
    #expect(diamond.height > plain.height)
  }

  /// Two polls of an unchanged board must draw the same picture — a diagram that shuffles
  /// itself between ticks is one nobody trusts.
  @Test
  func theSameBoardLaysOutTheSameWayTwice() {
    let subject = board([("A", "B"), ("A", "C"), ("B", "D"), ("C", "D")])
    #expect(BoardLayout(board: subject) == BoardLayout(board: subject))
  }

  @Test
  func aTableOrAOneBoxFlowLaysOutToNothing() {
    #expect(
      BoardLayout(
        board: SummaryBoard(
          form: .table, table: BoardTable(headers: ["a"], rows: [["b"]]), source: "", pass: 1)
      ).nodes.isEmpty)
    #expect(BoardLayout(board: board([], nodes: [BoardNode(id: "A", text: "A")])).nodes.isEmpty)
  }
}
