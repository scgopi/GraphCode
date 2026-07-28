import CoreGraphics
import SwiftUI
import Testing

@testable import graphcode

/// `NotebookGrid` draws only the rules that land on screen and reconstructs where they
/// belong from the canvas transform, so "is it in the right place" is arithmetic that a
/// glance at the app can't really check — a grid that has drifted half a cell out from
/// under the nodes still looks like a grid. These render it offscreen and read the
/// pixels back, which is the only way to see the drift.
@Suite
struct NotebookGridTests {
  private static let cell: CGFloat = 100
  private static let side: CGFloat = 400

  @Test
  @MainActor
  func rulesLandOnCellBoundariesWhenTheCanvasIsUntouched() {
    let ink = renderedInk(offset: .zero, scale: 1)
    #expect(ink.hasVerticalRule(at: 100))
    #expect(ink.hasVerticalRule(at: 300))
    #expect(!ink.hasVerticalRule(at: 150))
    #expect(ink.hasHorizontalRule(at: 200))
    #expect(!ink.hasHorizontalRule(at: 250))
  }

  @Test
  @MainActor
  func panningCarriesTheRulesWithTheGraph() {
    let ink = renderedInk(offset: CGSize(width: 25, height: 40), scale: 1)
    #expect(ink.hasVerticalRule(at: 125))
    #expect(!ink.hasVerticalRule(at: 100))
    #expect(ink.hasHorizontalRule(at: 140))
    #expect(!ink.hasHorizontalRule(at: 100))
  }

  /// The node layer is scaled about its center, so a rule at canvas x lands at
  /// cx + (x − cx)·scale. At 2× on a 400pt square that puts canvas x=100 at 0 and x=150
  /// at 100 — nowhere near the naive k·(cell·scale) a grid without the center term
  /// would draw. This is the assertion that catches the ruling sliding out from under
  /// the nodes on zoom.
  @Test
  @MainActor
  func zoomingKeepsTheRulesUnderTheNodesTheyBelongTo() {
    let ink = renderedInk(offset: .zero, scale: 2)
    #expect(ink.hasVerticalRule(at: 200))
    #expect(!ink.hasVerticalRule(at: 100))
    #expect(ink.hasHorizontalRule(at: 200))
  }

  @Test
  @MainActor
  func zoomingFarOutStopsDrawingRatherThanFillingTheCanvasWithLines() {
    let ink = renderedInk(offset: .zero, scale: 0.05)  // 5pt cells — a flat wash
    #expect(ink.isBlank)
  }

  @MainActor
  private func renderedInk(offset: CGSize, scale: CGFloat) -> InkMap {
    // Composited over black rather than rendered bare: an `ImageRenderer` image carries
    // no usable alpha, so "is there a rule here" has to be read as brightness, and the
    // grid color is the only thing on the canvas lighter than black.
    let renderer = ImageRenderer(
      content: NotebookGrid(cellSize: Self.cell, offset: offset, scale: scale)
        .frame(width: Self.side, height: Self.side)
        .background(Color.black)
    )
    renderer.scale = 1
    guard let image = renderer.cgImage else {
      Issue.record("ImageRenderer produced no image")
      return InkMap(brightness: [], width: 0, height: 0)
    }
    return InkMap(image: image)
  }
}

/// A rendered grid reduced to "is there a rule in this pixel" and nothing else.
private struct InkMap {
  /// Anything above the black backdrop is a rule. The grid color lands around 33/255,
  /// and an antialiased edge well above zero, so the threshold only has to clear
  /// rounding noise.
  private static let inkThreshold: UInt8 = 8

  let brightness: [UInt8]
  let width: Int
  let height: Int

  init(brightness: [UInt8], width: Int, height: Int) {
    self.brightness = brightness
    self.width = width
    self.height = height
  }

  init(image: CGImage) {
    width = image.width
    height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    brightness = pixels
  }

  var isBlank: Bool { !brightness.contains { $0 >= Self.inkThreshold } }

  /// A rule is a line that inks essentially its whole column; a column that merely
  /// *crosses* the rules running the other way picks up only a pixel per intersection,
  /// which is why this asks for a majority rather than for any ink at all.
  ///
  /// A 1pt rule centred on `pointX` can land either side of a pixel boundary depending on
  /// rounding, so a hit means "a rule in the pixel column at `pointX` or the one before it".
  func hasVerticalRule(at pointX: Int) -> Bool {
    [pointX - 1, pointX].contains { column in
      guard column >= 0, column < width else { return false }
      let inked = (0..<height).count { brightness[$0 * width + column] >= Self.inkThreshold }
      return inked > height / 2
    }
  }

  func hasHorizontalRule(at pointY: Int) -> Bool {
    [pointY - 1, pointY].contains { row in
      guard row >= 0, row < height else { return false }
      let inked = (0..<width).count { brightness[row * width + $0] >= Self.inkThreshold }
      return inked > width / 2
    }
  }
}
