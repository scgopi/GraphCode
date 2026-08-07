import CoreGraphics
import Foundation

/// Where a pan/zoom canvas is currently looking: a scale and an offset, applied in that
/// order (`.scaleEffect(scale)` then `.offset(offset)`, scaling anchored at the pane's
/// centre).
///
/// A value with the arithmetic on it rather than two `@State` numbers the view nudges
/// directly. Zoom-around-a-point is the reason: keeping the graph under the pointer (or
/// under the pinch) fixed while the scale changes needs the offset recomputed from both
/// the old and the new scale, and that is exactly the kind of two-variable step that
/// silently drifts when it's written inline in three different gesture handlers.
///
/// The model it inverts, for a content point `p` and pane centre `c`:
/// `screen = c + (p - c) * scale + offset`.
struct CanvasTransform: Equatable {
  /// How far a gesture or a zoom button may take the canvas. Past 3× the cards are just
  /// big; below 0.6× a card's title stops being readable, which is as far out as zooming
  /// by hand is worth doing.
  static let minScale: CGFloat = 0.6
  static let maxScale: CGFloat = 3
  /// How far out *fit-to-content* may go, which is further than a gesture may: a
  /// workspace several folders tall is a couple of thousand points across and cannot be
  /// framed at 60%, and a fit that leaves half the graph outside the pane is not a fit.
  /// Below 0.25× the cards are texture and there is nothing left to frame.
  static let minFitScale: CGFloat = 0.25
  /// One press of the zoom buttons (and ⌘=/⌘-). A quarter step is small enough to land
  /// on the scale you wanted and large enough that holding the key gets somewhere.
  static let step: CGFloat = 1.25

  var scale: CGFloat = 1
  var offset: CGSize = .zero

  /// Scaled to `requested`, keeping whatever is under `anchor` (a point in pane
  /// coordinates) exactly where it is. Clamped, so a hard pinch can't send the graph
  /// somewhere it can't be read.
  func zoomed(to requested: CGFloat, around anchor: CGPoint, in viewport: CGSize) -> Self {
    let clamped = min(max(requested, Self.minScale), Self.maxScale)
    guard scale > 0, viewport.width > 0, viewport.height > 0 else {
      return Self(scale: clamped, offset: offset)
    }
    // Solving `screen` unchanged for the new offset gives
    // `offset' = offset + (anchor - centre - offset) * (1 - new/old)`.
    let factor = 1 - clamped / scale
    let centreX = viewport.width / 2
    let centreY = viewport.height / 2
    return Self(
      scale: clamped,
      offset: CGSize(
        width: offset.width + (anchor.x - centreX - offset.width) * factor,
        height: offset.height + (anchor.y - centreY - offset.height) * factor))
  }

  /// One zoom step in or out, about the middle of the pane — what the buttons and the
  /// keyboard shortcuts do, since neither has a pointer position to zoom about.
  func stepped(by factor: CGFloat, in viewport: CGSize) -> Self {
    zoomed(
      to: scale * factor,
      around: CGPoint(x: viewport.width / 2, y: viewport.height / 2),
      in: viewport)
  }

  /// The whole graph in view at once. Never magnifies past 1× — "fit" on a two-loop
  /// workspace should show two ordinary cards, not two billboards.
  static func fitting(_ content: CGSize, in viewport: CGSize) -> Self {
    guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0
    else { return Self() }
    let raw = min(viewport.width / content.width, viewport.height / content.height)
    // A little margin, so the outermost cards aren't flush against the pane's edges.
    let scale = min(max(raw * 0.92, minFitScale), 1)
    return Self(scale: scale, offset: centringOffset(content, in: viewport, at: scale))
  }

  /// 1:1, with the graph centred — but never offset negatively. A graph wider or taller
  /// than the pane would otherwise be "centred" by pushing its origin off the top-left,
  /// which is where the start node and the folder chips live: the two things you most
  /// need to see before deciding where to pan.
  static func centred(_ content: CGSize, in viewport: CGSize) -> Self {
    let offset = centringOffset(content, in: viewport, at: 1)
    return Self(
      scale: 1,
      offset: CGSize(width: max(0, offset.width), height: max(0, offset.height)))
  }

  /// The offset that puts the content's centre at the pane's centre at a given scale.
  private static func centringOffset(
    _ content: CGSize, in viewport: CGSize, at scale: CGFloat
  ) -> CGSize {
    CGSize(
      width: (viewport.width / 2 - content.width / 2) * scale,
      height: (viewport.height / 2 - content.height / 2) * scale)
  }

  var canZoomIn: Bool { scale < Self.maxScale }
  var canZoomOut: Bool { scale > Self.minScale }

  /// What the zoom readout says. Rounded to whole percent — a canvas that reports
  /// "87.3%" is telling you about its float, not about your graph.
  var percentLabel: String { "\(Int((scale * 100).rounded()))%" }
}
