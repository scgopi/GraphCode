import CoreGraphics

/// Where an edge starts, stops, and points.
///
/// A handoff graph that draws undirected lines isn't saying the one thing it exists to
/// say. The arrowhead is the fix, and the arrowhead is why this is arithmetic rather
/// than a `Path` built inline: a head drawn at the target's *centre* lands underneath
/// the card, invisible at every zoom, so the line has to be trimmed to where it crosses
/// the card's border first.
///
/// Pure functions on points in canvas coordinates. The canvas applies its own
/// `scaleEffect`, so an anchor that is right at 100% is right at 40% and 250% too —
/// which is the property that would otherwise need three screenshots to check.
enum CanvasEdgeGeometry {
  static let arrowLength: CGFloat = 7
  static let arrowWidth: CGFloat = 7
  /// The blue pip on an edge that has fired.
  static let firedDotRadius: CGFloat = 2.5

  /// Where the segment `from → centre` crosses the border of a card of `size` centred at
  /// `centre`. The centre itself when the two points coincide — a degenerate edge has no
  /// direction to trim along, and returning something off-card would draw a head pointing
  /// at nothing.
  static func anchor(from: CGPoint, to centre: CGPoint, cardSize: CGSize) -> CGPoint {
    let dx = centre.x - from.x
    let dy = centre.y - from.y
    guard dx != 0 || dy != 0 else { return centre }

    // How far back along the ray the border is: whichever of the two half-extents is
    // reached first.
    let horizontal = dx == 0 ? CGFloat.infinity : (cardSize.width / 2) / abs(dx)
    let vertical = dy == 0 ? CGFloat.infinity : (cardSize.height / 2) / abs(dy)
    let step = min(horizontal, vertical)
    return CGPoint(x: centre.x - dx * step, y: centre.y - dy * step)
  }

  /// The three corners of the head at `tip`, pointing the way `from → tip` travels.
  static func arrowhead(at tip: CGPoint, from: CGPoint) -> [CGPoint] {
    let dx = tip.x - from.x
    let dy = tip.y - from.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return [] }

    let (ux, uy) = (dx / length, dy / length)
    let base = CGPoint(x: tip.x - ux * arrowLength, y: tip.y - uy * arrowLength)
    let half = arrowWidth / 2
    return [
      tip,
      CGPoint(x: base.x - uy * half, y: base.y + ux * half),
      CGPoint(x: base.x + uy * half, y: base.y - ux * half),
    ]
  }

  static func midpoint(_ from: CGPoint, _ to: CGPoint) -> CGPoint {
    CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
  }
}
