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

  /// Where an edge leaves its source: the trailing edge, at the card's vertical middle.
  ///
  /// Both ends attach at vertical middles and never at corners. A corner anchor reads as
  /// plumbing routed around an obstacle; a middle-to-middle curve reads as one loop
  /// handing to another, which is what it is.
  static func exit(from centre: CGPoint, toward target: CGPoint, cardSize: CGSize) -> CGPoint {
    let side: CGFloat = target.x >= centre.x ? 1 : -1
    return CGPoint(x: centre.x + side * cardSize.width / 2, y: centre.y)
  }

  /// Where it arrives: the facing edge of the target, again at the vertical middle.
  static func entry(at centre: CGPoint, from source: CGPoint, cardSize: CGSize) -> CGPoint {
    let side: CGFloat = source.x <= centre.x ? -1 : 1
    return CGPoint(x: centre.x + side * cardSize.width / 2, y: centre.y)
  }

  /// The two Bézier controls, horizontal-out and horizontal-in.
  ///
  /// Their x values stay **monotone** between the endpoints — clamped to the span rather
  /// than pushed past it. An overshooting control makes the curve leave the source
  /// heading away from the target and double back, which is the single thing that made
  /// the mocks read as pipework.
  static func controls(
    from start: CGPoint, to end: CGPoint
  ) -> (CGPoint, CGPoint) {
    let span = end.x - start.x
    // Enough curve to read as a curve even when the two cards are nearly in line.
    let reach = max(abs(span) * 0.5, 26)
    let outward = span >= 0 ? min(reach, max(span, reach)) : -min(reach, max(-span, reach))
    return (
      CGPoint(x: start.x + outward, y: start.y),
      CGPoint(x: end.x - outward, y: end.y)
    )
  }

  /// The tangent the curve arrives on, for pointing the arrowhead. Taken from the last
  /// control point rather than from the straight line between centres — on a curve those
  /// differ, and a head that ignores the difference sits askew on the border it lands on.
  static func arrivalTangent(control: CGPoint, end: CGPoint) -> CGPoint {
    CGPoint(x: end.x * 2 - control.x, y: end.y * 2 - control.y)
  }
}
