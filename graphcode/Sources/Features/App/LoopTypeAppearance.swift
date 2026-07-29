import GraphcodeKit
import SwiftUI

/// How a `LoopType` is distinguished on a graph — one colour and one glyph per kind,
/// shared by the project canvas and the cross-project overview so a loop looks the same
/// wherever you meet it. Lives in the app target for the same reason
/// `LoopState.presenceColor` does: `GraphcodeKit` is linked into the plain `graphcoded`
/// daemon and stays free of SwiftUI.
///
/// **Colour is never the only signal.** Every card already spells the type out, and the
/// glyph below is a second non-colour channel. That matters here: four hues that stay
/// mutually distinguishable under *every* kind of colour blindness don't exist within one
/// lightness band — validated, not assumed, and the run is recorded below — so the
/// palette is only legitimate alongside the label and glyph that travel with it.
///
/// The hues are the data-viz reference palette's dark-surface steps. Against this app's
/// canvas they pass the lightness band, the chroma floor, adjacent-pair CVD separation
/// (worst ΔE 8.4, protan), the normal-vision floor (worst ΔE 19.3), and 3:1 contrast.
/// Under all-pairs rather than adjacent, magenta and aqua collapse for deuteranopes
/// (ΔE 1.6) — which is exactly what the label and glyph are for.
///
/// Blue and orange are deliberately absent. Both are spoken for elsewhere on the same
/// card and would say two things at once: blue is a running loop's presence dot, orange
/// is "needs attention" on the border and the attention label.
extension LoopType {
  /// The kind's colour. Used for the card's edge stripe and its glyph — never for text,
  /// which keeps its own ink so the colour beside it is what carries identity.
  var accent: Color {
    switch self {
    case .goalBased: Color(red: 0.098, green: 0.620, blue: 0.439)  // aqua  #199e70
    case .timeBased: Color(red: 0.788, green: 0.522, blue: 0.000)  // yellow #c98500
    case .turnBased: Color(red: 0.835, green: 0.318, blue: 0.506)  // magenta #d55181
    case .proactive: Color(red: 0.565, green: 0.522, blue: 0.914)  // violet #9085e9
    }
  }

  /// A glyph that says what the kind *does*, so the distinction survives without colour:
  /// a goal-based loop runs at a target, a time-based one at a clock, a turn-based one
  /// waits for a person, and a proactive one is a stack of loops rather than a session.
  var glyph: String {
    switch self {
    case .goalBased: "target"
    case .timeBased: "clock"
    case .turnBased: "person"
    case .proactive: "square.stack.3d.up"
    }
  }
}
