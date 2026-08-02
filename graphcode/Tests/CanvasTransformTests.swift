import CoreGraphics
import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The Graph view's pan/zoom arithmetic. Worth testing away from SwiftUI because the one
/// property that makes zooming feel right — whatever is under the pointer stays under the
/// pointer — is a statement about two scales and an offset, and is invisible in a
/// screenshot until it's wrong.
@Suite
struct CanvasTransformTests {
  private static let viewport = CGSize(width: 800, height: 600)

  /// Where a content point lands on screen, per the model `CanvasTransform` inverts.
  private func screenPosition(
    of point: CGPoint, under transform: CanvasTransform, in viewport: CGSize
  ) -> CGPoint {
    CGPoint(
      x: viewport.width / 2 + (point.x - viewport.width / 2) * transform.scale
        + transform.offset.width,
      y: viewport.height / 2 + (point.y - viewport.height / 2) * transform.scale
        + transform.offset.height)
  }

  @Test
  func zoomingKeepsWhatIsUnderThePointerUnderThePointer() {
    let anchor = CGPoint(x: 220, y: 140)
    var transform = CanvasTransform()
    // The content point that happens to sit under the anchor before zooming.
    let content = CGPoint(x: 220, y: 140)
    #expect(screenPosition(of: content, under: transform, in: Self.viewport) == anchor)

    transform = transform.zoomed(to: 2.5, around: anchor, in: Self.viewport)
    let after = screenPosition(of: content, under: transform, in: Self.viewport)
    #expect(abs(after.x - anchor.x) < 0.001)
    #expect(abs(after.y - anchor.y) < 0.001)

    // And back out again, from a scale that isn't 1 — the step that drifts when the
    // offset is recomputed from only one of the two scales.
    transform = transform.zoomed(to: 0.6, around: anchor, in: Self.viewport)
    let backOut = screenPosition(of: content, under: transform, in: Self.viewport)
    #expect(abs(backOut.x - anchor.x) < 0.001)
    #expect(abs(backOut.y - anchor.y) < 0.001)
  }

  @Test
  func scaleIsClampedSoAHardPinchCannotLoseTheGraph() {
    let anchor = CGPoint(x: 400, y: 300)
    let tiny = CanvasTransform().zoomed(to: 0.001, around: anchor, in: Self.viewport)
    let huge = CanvasTransform().zoomed(to: 500, around: anchor, in: Self.viewport)
    #expect(tiny.scale == CanvasTransform.minScale)
    #expect(huge.scale == CanvasTransform.maxScale)
    #expect(!tiny.canZoomOut)
    #expect(!huge.canZoomIn)
  }

  @Test
  func steppingInAndBackOutReturnsToWhereItStarted() {
    let start = CanvasTransform()
    let stepped =
      start
      .stepped(by: CanvasTransform.step, in: Self.viewport)
      .stepped(by: 1 / CanvasTransform.step, in: Self.viewport)
    #expect(abs(stepped.scale - start.scale) < 0.001)
    #expect(abs(stepped.offset.width - start.offset.width) < 0.001)
    #expect(abs(stepped.offset.height - start.offset.height) < 0.001)
  }

  @Test
  func fittingPutsTheWholeGraphInViewAndCentresIt() {
    // Far wider and taller than the pane — the case the overview actually hits, since a
    // workspace of several folders is a couple of thousand points across.
    let content = CGSize(width: 2400, height: 1800)
    let transform = CanvasTransform.fitting(content, in: Self.viewport)

    #expect(transform.scale < 1)
    #expect(content.width * transform.scale <= Self.viewport.width)
    #expect(content.height * transform.scale <= Self.viewport.height)

    // The graph's centre lands in the middle of the pane.
    let centre = screenPosition(
      of: CGPoint(x: content.width / 2, y: content.height / 2), under: transform,
      in: Self.viewport)
    #expect(abs(centre.x - Self.viewport.width / 2) < 0.001)
    #expect(abs(centre.y - Self.viewport.height / 2) < 0.001)
  }

  @Test
  func fittingNeverMagnifiesASmallGraph() {
    // Two loops in one folder shouldn't become billboards just because there's room.
    let transform = CanvasTransform.fitting(CGSize(width: 300, height: 200), in: Self.viewport)
    #expect(transform.scale == 1)
  }

  @Test
  func fittingFramesEveryLaneBandIncludingItsCaption() {
    // ⌘9 on a real workspace: three folders, a dozen loops. A band whose caption falls
    // outside the viewport is a lane you can't identify, and the caption is at the very
    // top-left corner of the band — the first thing a slightly-too-tight fit loses.
    let graphs = (0..<3).map { index in
      LoopGraph(
        project: ProjectRef(path: "/tmp/p\(index)", name: "p\(index)"),
        nodes: IdentifiedArrayOf<LoopNode>(
          uniqueElements: (0..<4).map { LoopNode(title: "loop-\(index)-\($0)") }))
    }
    let overview = GraphOverview(graphs: graphs)
    let transform = CanvasTransform.fitting(overview.size, in: Self.viewport)

    for band in overview.folders.map(\.band) {
      let corners = [
        CGPoint(x: band.minX, y: band.minY), CGPoint(x: band.maxX, y: band.maxY),
      ]
      for corner in corners {
        let onScreen = screenPosition(of: corner, under: transform, in: Self.viewport)
        #expect(onScreen.x >= 0 && onScreen.x <= Self.viewport.width)
        #expect(onScreen.y >= 0 && onScreen.y <= Self.viewport.height)
      }
    }
  }

  @Test
  func actualSizeNeverPushesTheGraphsTopLeftOffScreen() {
    // A graph bigger than the pane can't be centred without moving its origin off
    // screen — and the origin is where the first lane band and its caption are.
    let transform = CanvasTransform.centred(CGSize(width: 2400, height: 1800), in: Self.viewport)
    #expect(transform.scale == 1)
    #expect(transform.offset.width == 0)
    #expect(transform.offset.height == 0)
  }

  @Test
  func aDegenerateViewportChangesTheScaleWithoutProducingNaNs() {
    // The first layout pass can hand a view a zero size; dividing by it would poison the
    // offset for every gesture after.
    let transform = CanvasTransform().zoomed(to: 2, around: .zero, in: .zero)
    #expect(transform.scale == 2)
    #expect(transform.offset == .zero)
    #expect(CanvasTransform.fitting(.zero, in: Self.viewport) == CanvasTransform())
  }

  @Test
  func theReadoutIsWholePercent() {
    #expect(CanvasTransform(scale: 1).percentLabel == "100%")
    #expect(CanvasTransform(scale: 0.4).percentLabel == "40%")
    #expect(CanvasTransform(scale: 1.253).percentLabel == "125%")
  }
}

/// The band a lane of cards sits in — what replaced the start marker and its tethers.
/// The property that matters is that it encloses every card with room to spare: a band
/// that crops its own contents reads as a misdrawn rectangle rather than as a group.
@Suite
struct CanvasBandTests {
  private static let card = CGSize(width: 250, height: 106)

  @Test
  func theBandClearsEveryCardItEncloses() {
    let positions = [CGPoint(x: 200, y: 150), CGPoint(x: 700, y: 400)]
    let rect = CanvasBand.rect(around: positions, cardSize: Self.card, captioned: false)

    let cards = positions.map {
      CGRect(
        x: $0.x - Self.card.width / 2, y: $0.y - Self.card.height / 2,
        width: Self.card.width, height: Self.card.height)
    }
    #expect(cards.allSatisfy { rect?.contains($0) == true })
    #expect(rect?.minX == 200 - Self.card.width / 2 - CanvasBand.padding)
    #expect(rect?.maxY == 400 + Self.card.height / 2 + CanvasBand.padding)
  }

  @Test
  func aCaptionedBandGrowsUpwardsSoTheCaptionSitsAboveTheCards() {
    // The caption lives inside the band at its top-left. Without the extra strip it
    // would print over the first row of cards.
    let positions = [CGPoint(x: 200, y: 150)]
    let plain = CanvasBand.rect(around: positions, cardSize: Self.card, captioned: false)
    let captioned = CanvasBand.rect(around: positions, cardSize: Self.card, captioned: true)

    #expect(captioned?.minY == (plain?.minY ?? 0) - CanvasBand.captionHeight)
    #expect(captioned?.maxY == plain?.maxY)
  }

  @Test
  func anEmptyCanvasHasNoBand() {
    // A band around nothing is a rectangle on a blank pane, and `CanvasEmptyState` is
    // already explaining that.
    #expect(CanvasBand.rect(around: [], cardSize: Self.card, captioned: true) == nil)
  }
}

/// Where an edge stops and which way it points. Pure arithmetic on canvas coordinates,
/// which is the whole reason it can be checked here: the canvas applies its own
/// `scaleEffect`, so an anchor that lands on the card's border at 100% lands there at
/// 40% and 250% too — the three zoom levels the manual script asks for.
@Suite
struct CanvasEdgeGeometryTests {
  fileprivate static let card = CGSize(width: 250, height: 106)

  @Test
  func theHeadStopsOnTheCardsBorderRatherThanUnderIt() {
    // Straight in from the left: the head belongs on the leading edge, half a card's
    // width back from the centre.
    let anchor = CanvasEdgeGeometry.anchor(
      from: CGPoint(x: 100, y: 300), to: CGPoint(x: 600, y: 300), cardSize: Self.card)

    #expect(anchor == CGPoint(x: 600 - Self.card.width / 2, y: 300))
  }

  @Test
  func aSteepEdgeStopsOnTheTopBorderInsteadOfTheSide() {
    // Trimming by half-width alone would leave the head floating well above a card
    // approached from directly overhead.
    let anchor = CanvasEdgeGeometry.anchor(
      from: CGPoint(x: 600, y: 0), to: CGPoint(x: 600, y: 300), cardSize: Self.card)

    #expect(anchor == CGPoint(x: 600, y: 300 - Self.card.height / 2))
  }

  @Test
  func theAnchorIsAlwaysOnTheBorderWhateverTheAngle() {
    let centre = CGPoint(x: 600, y: 300)
    for degrees in stride(from: 0, to: 360, by: 15) {
      let radians = Double(degrees) * .pi / 180
      let source = CGPoint(x: centre.x + cos(radians) * 400, y: centre.y + sin(radians) * 400)
      let anchor = CanvasEdgeGeometry.anchor(from: source, to: centre, cardSize: Self.card)

      let dx = abs(anchor.x - centre.x)
      let dy = abs(anchor.y - centre.y)
      // On the border means: one axis is exactly at its half-extent, neither is past it.
      let onEdge =
        abs(dx - Self.card.width / 2) < 0.001 || abs(dy - Self.card.height / 2) < 0.001
      #expect(onEdge)
      #expect(dx <= Self.card.width / 2 + 0.001)
      #expect(dy <= Self.card.height / 2 + 0.001)
    }
  }

  @Test
  func aDegenerateEdgeDrawsNoHeadRatherThanOnePointingNowhere() {
    let point = CGPoint(x: 40, y: 40)
    #expect(
      CanvasEdgeGeometry.anchor(from: point, to: point, cardSize: Self.card) == point)
    #expect(CanvasEdgeGeometry.arrowhead(at: point, from: point).isEmpty)
  }

  @Test
  func theHeadPointsTheWayTheEdgeTravels() {
    let corners = CanvasEdgeGeometry.arrowhead(
      at: CGPoint(x: 300, y: 100), from: CGPoint(x: 100, y: 100))

    #expect(corners.count == 3)
    #expect(corners[0] == CGPoint(x: 300, y: 100))
    // The two back corners sit one arrow-length behind the tip, either side of the line.
    #expect(corners.dropFirst().allSatisfy { $0.x == 300 - CanvasEdgeGeometry.arrowLength })
    #expect(
      abs(corners[1].y - corners[2].y) == CanvasEdgeGeometry.arrowWidth)
  }

  @Test
  func bothEndsAttachAtTheCardsVerticalMiddles() {
    // Corner anchors read as plumbing routed around an obstacle. Middle-to-middle reads
    // as one loop handing to another, which is what it is.
    let source = CGPoint(x: 200, y: 300)
    let target = CGPoint(x: 800, y: 460)

    let exit = CanvasEdgeGeometry.exit(from: source, toward: target, cardSize: Self.card)
    let entry = CanvasEdgeGeometry.entry(at: target, from: source, cardSize: Self.card)

    #expect(exit == CGPoint(x: source.x + Self.card.width / 2, y: source.y))
    #expect(entry == CGPoint(x: target.x - Self.card.width / 2, y: target.y))
  }

  @Test
  func anEdgeRunningRightToLeftLeavesAndArrivesOnTheFacingSides() {
    let source = CGPoint(x: 800, y: 300)
    let target = CGPoint(x: 200, y: 300)

    #expect(
      CanvasEdgeGeometry.exit(from: source, toward: target, cardSize: Self.card)
        == CGPoint(x: source.x - Self.card.width / 2, y: source.y))
    #expect(
      CanvasEdgeGeometry.entry(at: target, from: source, cardSize: Self.card)
        == CGPoint(x: target.x + Self.card.width / 2, y: target.y))
  }

  @Test
  func controlPointsStayBetweenTheEndsRatherThanOvershooting() {
    // The single thing that made the mocks read as pipework: a control past the far end
    // makes the curve leave the source heading away from the target and double back.
    for (start, end) in [
      (CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 120)),
      (CGPoint(x: 400, y: 0), CGPoint(x: 0, y: 120)),
      (CGPoint(x: 0, y: 0), CGPoint(x: 12, y: 200)),
    ] {
      let (first, second) = CanvasEdgeGeometry.controls(from: start, to: end)
      let low = min(start.x, end.x)
      let high = max(start.x, end.x)
      // Monotone in x: each control is on its own side of the span, never past the other
      // endpoint by more than the minimum reach that keeps a near-vertical edge curved.
      #expect(first.x >= min(low, start.x) - 0.001)
      #expect(second.x <= max(high, end.x) + 26.001)
      // Horizontal-out and horizontal-in: the controls share their endpoint's y, which
      // is what makes the curve leave and arrive level.
      #expect(first.y == start.y)
      #expect(second.y == end.y)
    }
  }

  @Test
  func theHeadPointsAlongTheCurvesArrivalRatherThanTheStraightLine() {
    // On a curve those differ, and a head that ignores the difference sits askew on the
    // border it lands on.
    let start = CGPoint(x: 0, y: 0)
    let end = CGPoint(x: 300, y: 200)
    let (_, second) = CanvasEdgeGeometry.controls(from: start, to: end)
    let approach = CanvasEdgeGeometry.arrivalTangent(control: second, end: end)

    // The tangent continues past the end on the line from the last control, so the head
    // is aimed level — the same direction the curve is travelling as it lands.
    #expect(approach.y == end.y)
    #expect(approach.x > end.x)
  }
}
