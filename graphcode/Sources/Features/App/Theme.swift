import SwiftUI

/// The window's chrome. graphcode is a dark tool that spends its life next to terminals,
/// so the window is a fixed dark gray keyed to the app icon's body rather than a system
/// material — materials shift value with the wallpaper behind them and go flat when the
/// window loses focus, which makes the graph canvas look like it changed color.
///
/// **One tone, everywhere**: `windowBackground` (`#1E1E1E`) is the sidebar, the titlebar,
/// the canvas, the tab strip and the terminal alike, and the chrome only varies around it
/// by the few points of gloss that say where the light is. Sampled off supacode, which is
/// flat within four values from titlebar to terminal.
///
/// The two arrangements this replaced are both worth not repeating. A ladder of greys —
/// window, then sidebar a step under, then canvas under that — meant every boundary was a
/// colour change, and the eye reads a colour change as an object. Then the panes went to
/// real black, which forced every piece of chrome to be *some* grey just to be visible,
/// and the tab strip ended up the brightest thing in the window. One tone dissolves the
/// problem instead of tuning it: boundaries are hairlines and shadows, and the only real
/// colour left in the window is a loop's own.
///
/// Chrome is *painted* glossy — a gradient lit from above, a specular line on its top
/// edge, a shadow line where it meets the next pane (`sidebarGloss`, `tabBarGloss`). Not
/// a system material, for the reason above: glass would let the wallpaper tint the one
/// piece of chrome that has to hold still, and desaturate it the moment the window lost
/// focus.
enum Theme {
  /// The one value nearly every surface in this app is: `#1E1E1E`.
  ///
  /// Sampled off supacode, which is the reference for this and turns out to be a single
  /// flat tone from titlebar to terminal — sidebar `28,28,28`, tab strip `27,30,30`,
  /// terminal `27,31,31`. Not black, and not a stack of greys either. Real black is what
  /// this used to be, and against it every piece of chrome had to be *some* grey to be
  /// visible at all, which is how the window ended up with a light strip across the top
  /// of a black pane. One tone removes the problem rather than tuning it.
  ///
  /// Neutral rather than the blue-tinted greys the rest of this file used to carry —
  /// supacode is dead neutral, and a tint only shows itself when there is something
  /// untinted beside it to compare against.
  static let windowBackground = Color(white: 0.118)

  /// The sidebar's fill: one light source above the titlebar, falling off down the pane.
  ///
  /// Centred on `windowBackground` rather than sitting a step off it — it starts a shade
  /// above and ends a shade below, so the pane averages out to the same tone as
  /// everything else and the gloss is light on one surface instead of a second colour.
  ///
  /// **Why this is painted and not `NSVisualEffectView(.sidebar)`**, which is what a
  /// native Mac sidebar actually is: that material blurs and *tints from the desktop
  /// wallpaper* behind the window, and desaturates the moment the window stops being key.
  /// The one piece of chrome that has to hold still would be the one piece that never
  /// does, and the sidebar would change color when you moved the window. Everything below
  /// is the Aqua recipe that material replaced — vertical gloss, specular top edge,
  /// shadow where the next pane begins — which is why it still reads as a Mac sidebar
  /// without borrowing the wallpaper to do it.
  ///
  /// Stops rather than evenly spaced colors, because evenly spaced is what made the old
  /// version invisible: a linear ramp over a full window height is a 1-value-per-hundred
  /// -points change, which is nothing. Real gloss puts most of its falloff in the top
  /// fifth — near the light — and is almost flat below that. Same shape as `tabBarGloss`,
  /// stretched over a pane instead of a 40pt strip.
  /// Since the sidebar grew sections (Graph/chats, local, remote), it sits well under
  /// `windowBackground` rather than centred on it — first a ~15% step, then deepened
  /// to ~28% (centre ≈0.085) on review: the subtler version didn't recess enough to
  /// read as the frame around the lit workspace. Deliberately the one exception to the
  /// one-tone rule above; the floor to respect is the real-black era's lesson — much
  /// below this and every piece of chrome has to fight to be visible again.
  static let sidebarGloss = LinearGradient(
    stops: [
      .init(color: Color(white: 0.100), location: 0.00),
      .init(color: Color(white: 0.084), location: 0.16),
      .init(color: Color(white: 0.073), location: 0.48),
      .init(color: Color(white: 0.057), location: 1.00),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The specular line along the sidebar's top edge, where it meets the titlebar — the
  /// thing that actually says "lit from above" rather than "filled with a gradient".
  /// Still under the tab strip's: this rule runs the full width of a tall pane, and at
  /// the strip's brightness it stops reading as light and starts reading as a border.
  static let sidebarHighlight = Color.white.opacity(0.07)

  /// The shadow where the sidebar meets the detail pane — and, now that both panes are the
  /// same tone, the only thing separating them at all. A `NavigationSplitView`'s own
  /// divider is nearly invisible between two dark fills, and a hairline of black reads as
  /// the content pane casting into the recess rather than as a drawn line.
  static let sidebarEdgeShadow = Color.black.opacity(0.45)

  /// Graph canvas fill — both canvases, the Graph overview and a project's. Darkened
  /// below `windowBackground` in the same review that recessed the sidebar: with the
  /// sidebar sitting at ~0.073, a canvas still at the window tone read as the brightest
  /// pane in the window, and the cards lost their lift. A shade above the sidebar keeps
  /// the ordering — sidebar deepest, canvas above it, cards and chrome on top.
  static let canvasBackground = Color(white: 0.095)

  /// The canvas's notebook ruling. One step off `canvasBackground` and no further: the
  /// grid is there to give panning something to move against and to make the empty
  /// canvas read as a surface, so it has to lose to every edge and node drawn over it.
  ///
  /// It moves *with* the canvas — a ruling is only ever "one step off" whatever it is
  /// drawn on, which is why it darkened in step when the canvas did.
  static let canvasGridLine = Color(white: 0.155)

  /// A loop workspace's tab strip — the sidebar's gloss, on a strip instead of a pane.
  ///
  /// Painted rather than a system material for the reason at the top of this file: glass
  /// would desaturate the strip whenever the window lost focus and let the wallpaper tint
  /// it, so the one piece of chrome sitting against the terminal would be the one piece
  /// that never held still.
  ///
  /// It used to top out at 0.180 against a black terminal, and that was the grey band
  /// across the top of the window — the strip was the brightest thing on screen, which is
  /// exactly backwards for a row of tab labels. What separates it from the terminal now is
  /// `tabBarShadowLine` below it, not its own value.
  static let tabBarGloss = LinearGradient(
    colors: [
      Color(white: 0.145),
      Color(white: 0.122),
      Color(white: 0.106),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The specular line along the strip's top edge — what actually sells "lit from
  /// above". Kept to one point: any thicker and it reads as a border.
  static let tabBarHighlight = Color.white.opacity(0.08)

  /// The shadow line where the strip meets the terminal, so the gloss ends on an edge
  /// rather than fading into the pane below it.
  static let tabBarShadowLine = Color.black.opacity(0.35)

  /// Laid over the unfocused half of a split, so the pane you are typing into is the one
  /// that looks live.
  ///
  /// The terminal's own background at 35% — heavier than Ghostty's own
  /// `unfocused-split-opacity` (0.85, i.e. a 15% veil), which was too faint to tell the
  /// two halves apart at a glance. It still pulls the inactive pane's text toward the
  /// background rather than greying it, so that pane stays readable — which matters
  /// because the whole reason to split is watching one pane while working in the other.
  static let unfocusedPaneVeil = windowBackground.opacity(0.35)

  /// The folder glyph in a loop workspace's header — the Finder blue, so a folder on a
  /// dark chrome strip reads as a folder before you've read the name next to it.
  static let folderGlyph = Color(red: 0.365, green: 0.647, blue: 0.937)

  /// A small control sitting on the tab strip — the split and new-tab buttons. Lit the
  /// same way as `tabBarGloss` but a step brighter, so the buttons read as raised off
  /// the strip rather than as glyphs printed on it.
  static let controlGloss = LinearGradient(
    colors: [
      Color(red: 0.243, green: 0.255, blue: 0.278),
      Color(red: 0.192, green: 0.200, blue: 0.220),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// Same, brightened for hover — the only feedback these buttons have.
  static let controlGlossHovered = LinearGradient(
    colors: [
      Color(red: 0.310, green: 0.322, blue: 0.349),
      Color(red: 0.243, green: 0.255, blue: 0.278),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The lit top edge of a control, matching `tabBarHighlight`'s role on the strip.
  static let controlBorder = Color.white.opacity(0.10)

  /// The selected tab's pill — lighter than `tabBarGloss` so it stands off the
  /// strip the way a real terminal app's active tab does, without reaching for the
  /// system accent color (this isn't a selection, it's "what's showing").
  static let tabSelectedBackground = Color(red: 0.235, green: 0.245, blue: 0.267)
}
