import CoreGraphics
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
  func actualSizeNeverPushesTheStartNodeOffTheTopLeft() {
    // A graph bigger than the pane can't be centred without moving its origin off
    // screen — and the origin is where the start marker and the folder chips are.
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

/// Where a canvas's start marker goes. The regression this guards is subtle to see and
/// obvious once you do: at the grid's first column (x=160) the old `leftmost - 150` put
/// the marker at x=10, clipped against the pane's edge — which reads as no start node.
@Suite
struct CanvasStartTests {
  @Test
  func theMarkerSitsLeftOfTheLeftmostCardAndCentredOnTheGraph() {
    let origin = CanvasStart.origin(of: [
      CGPoint(x: 600, y: 100), CGPoint(x: 900, y: 500), CGPoint(x: 640, y: 300),
    ])
    #expect(origin == CGPoint(x: 600 - CanvasStart.gap, y: 300))
  }

  @Test
  func theMarkerNeverClipsAgainstThePanesLeftEdge() {
    // The project canvas's own first column, which is what made this visible.
    let origin = CanvasStart.origin(of: [CGPoint(x: 160, y: 140), CGPoint(x: 420, y: 140)])
    #expect(origin?.x == CanvasStart.minimumX)
  }

  @Test
  func aGraphWithNoCardsHasNoOrigin() {
    // An origin with nothing hanging off it is a dot in an empty field, and the canvas's
    // empty state already explains itself. Nothing to originate, nothing to draw.
    #expect(CanvasStart.origin(of: []) == nil)
  }
}
