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
/// Chrome that sits against the terminal is *painted* glossy — a gradient lit from
/// above, a specular line on its top edge, a shadow line where it meets the next pane
/// (`tabBarGloss`). Not a system material, for the reason above: glass would let the
/// wallpaper tint the one piece of chrome that has to hold still, and desaturate it
/// the moment the window lost focus.
///
/// The sidebar is the deliberate exception since adopting the system's glass: it is
/// the native sidebar material again (Liquid Glass on macOS 26), per Apple's Liquid
/// Glass adoption guidance that custom backgrounds in split views interfere with the
/// system effect and should be removed. The desktop tinting it is that effect's point;
/// `.preferredColorScheme(.dark)` keeps it dark. See `AppSidebarView`.
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

  /// Graph canvas fill — both canvases, the Graph overview and a project's. Darkened
  /// below `windowBackground` in the review that recessed the (then-painted) sidebar:
  /// a canvas at the window tone read as the brightest pane in the window, and the
  /// cards lost their lift. The ordering it keeps — sidebar deepest, canvas above it,
  /// cards and chrome on top — survives the sidebar's move to the system material,
  /// which in dark appearance sits visually below this value.
  static let canvasBackground = Color(white: 0.095)

  /// The canvas's notebook ruling. One step off `canvasBackground` and no further: the
  /// grid is there to give panning something to move against and to make the empty
  /// canvas read as a surface, so it has to lose to every edge and node drawn over it.
  ///
  /// It moves *with* the canvas — a ruling is only ever "one step off" whatever it is
  /// drawn on, which is why it darkened in step when the canvas did.
  static let canvasGridLine = Color(white: 0.155)

  /// A loop workspace's tab strip — painted gloss on a 40pt strip: one light source
  /// above, most of the falloff near it.
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
