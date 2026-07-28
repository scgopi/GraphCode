import CoreGraphics

/// Where a canvas's start marker goes, given where its cards ended up.
///
/// Left of the leftmost card and centred on the graph's vertical extent, so the tethers
/// fan out rather than doubling back over the cards — and never closer to the left edge
/// than `minimumX`, which is the part that was actually wrong: the project canvas lays
/// its first column out at x=160, so a plain `leftmost - gap` put the marker at x=10 with
/// half the dot and most of its "Start" caption clipped off the pane. A start node you
/// cannot see is indistinguishable from one that was never drawn.
///
/// A free function on a caseless enum rather than a computed property on the view,
/// because both canvases want the same answer and the clipping bug is exactly the kind
/// that's invisible until someone opens the app with a full-width graph.
enum CanvasStart {
  /// Horizontal distance from the leftmost card's *centre*. Has to clear the card's own
  /// half-width (110pt) plus the marker's, or the origin ends up drawn underneath the
  /// very first card.
  static let gap: CGFloat = 150
  /// Only a guard against negative coordinates, which would put the marker outside the
  /// bounds `CanvasTransform.fitting`/`.centred` measure and quietly crop it. Keeping the
  /// marker *on screen* is the canvas's job, not this floor's: both canvases centre their
  /// content on first paint, which is what brings the left edge into view.
  static let minimumX: CGFloat = 10

  /// `nil` for a graph with no cards: an origin with nothing hanging off it is a dot in
  /// an empty field, and the canvas's empty state (`CanvasEmptyState`) already says what
  /// is going on and what to do about it. A marker there would be one more unexplained
  /// thing on a screen whose whole job at that moment is to explain itself.
  static func origin(of positions: [CGPoint]) -> CGPoint? {
    guard let leftmost = positions.map(\.x).min(),
      let top = positions.map(\.y).min(),
      let bottom = positions.map(\.y).max()
    else { return nil }
    return CGPoint(x: max(leftmost - gap, minimumX), y: (top + bottom) / 2)
  }
}
