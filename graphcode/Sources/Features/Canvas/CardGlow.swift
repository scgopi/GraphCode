import SwiftUI

/// The glow a canvas card floats on — both canvases, the Graph overview and a
/// project's, so a loop reads as equally "on top" wherever it appears.
///
/// Cards sit on a canvas that is itself a dark scrim over glass (`Theme`), and a plain
/// black drop shadow all but vanishes against it — the card ends at its hairline stroke
/// and reads as printed *on* the sheet rather than floating above it. Elevation on a
/// surface this dark needs two things a light theme gets for free:
///
/// - a **contact shadow**, tight and dark, so the card has an underside;
/// - a **glow**, wide and faintly tinted by the card's own accent, standing in for the
///   ambient shadow that has nothing dark left to darken. The tint keeps the halo from
///   reading as a focus ring — it belongs to the card, not to selection.
///
/// One modifier rather than shadow calls at each card site so the canvases can't
/// drift apart card by card, and so the radii stay tuned together: the glow has to
/// lose to `EdgeLineView`'s strokes and the notebook ruling has to lose to the glow.
extension View {
  /// `accent` is the card's own hue — a loop card passes its `loopType.accent`, a
  /// folder chip has no kind so it passes nothing and gets a neutral lift.
  /// `emphasized` widens and warms nothing by itself; it simply strengthens the halo —
  /// used for attention, where the orange stroke already names the reason and the glow
  /// makes it findable from across a zoomed-out graph.
  func cardGlow(_ accent: Color = .white, emphasized: Bool = false) -> some View {
    self
      .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
      .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
      .shadow(
        color: accent.opacity(emphasized ? 0.45 : 0.16),
        radius: emphasized ? 18 : 12)
  }
}
