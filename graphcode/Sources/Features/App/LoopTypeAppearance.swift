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
    // Deliberately colourless: the four committed types keep the saturated slots, and
    // grey reads as *provisional* — a canvas of half-finished pokes shouldn't compete
    // with work that matters.
    case .sketch: Color(red: 0.486, green: 0.529, blue: 0.580)  // grey  #7c8794
    case .goalBased: Color(red: 0.098, green: 0.620, blue: 0.439)  // aqua  #199e70
    case .timeBased: Color(red: 0.788, green: 0.522, blue: 0.000)  // yellow #c98500
    case .turnBased: Color(red: 0.835, green: 0.318, blue: 0.506)  // magenta #d55181
    case .composite: Color(red: 0.565, green: 0.522, blue: 0.914)  // violet #9085e9
    }
  }

  /// What the kind is called on a card, a row, or anywhere else a graph is being read.
  ///
  /// One word, because it shares a meta row with a branch name, a backend, and an
  /// elapsed time, and the kind is the least of those once you know the graph. The
  /// form's longer "Goal-based" phrasing stays in the form, where you are choosing a
  /// kind rather than recognising one.
  ///
  /// Anything user-facing goes through here. `rawValue` is a serialisation detail, and
  /// showing `goalBased` to a human while the form beside it says "Goal-based" was the
  /// app admitting it had two vocabularies.
  var displayName: String {
    switch self {
    case .sketch: "Main"
    case .goalBased: "Goal"
    case .timeBased: "Timed"
    case .turnBased: "Turn"
    case .composite: "Composite"
    }
  }

  /// A glyph that says what the kind *does*, so the distinction survives without colour:
  /// a goal-based loop runs at a target, a time-based one at a clock, a turn-based one
  /// waits for a person, and a composite one is a stack of loops rather than a session.
  var glyph: String {
    switch self {
    case .sketch: "scribble"
    case .goalBased: "target"
    case .timeBased: "clock"
    case .turnBased: "person"
    case .composite: "square.stack.3d.up"
    }
  }
}
