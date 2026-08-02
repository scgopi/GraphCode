import SwiftUI

/// The window's chrome. graphcode is a dark tool that spends its life next to terminals.
///
/// **Glass under scrims**: since adopting the system's glass the window itself is
/// `.ultraThinMaterial` (`AppView`'s container background), and the Theme tones below
/// are translucent *scrims* laid over it rather than opaque paint. Every pane shows the
/// desktop glowing through to a different degree — the sidebar is bare glass, chrome and
/// canvas carry progressively heavier scrims, and the terminal is the most solid
/// (Ghostty's own `background-opacity`, which dims only the background and leaves text
/// crisp). `.preferredColorScheme(.dark)` keeps all of it dark regardless of wallpaper.
///
/// **One tone, everywhere** still holds for what the scrims are made of: the same
/// `#1E1E1E`-family values that used to be opaque, so panes differ by depth and gloss,
/// not by colour. The earlier arrangements remain worth not repeating: a ladder of greys
/// made every boundary read as an object, and real black forced every piece of chrome to
/// be some grey just to be visible.
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
  /// The tone nearly every scrim in this app is mixed from: `#1E1E1E`, sampled off
  /// supacode, dead neutral. Kept opaque here so things that need the tone at full
  /// strength (the unfocused-pane veil, the terminal's background colour) don't
  /// compound with scrim opacity.
  static let windowTone = Color(white: 0.118)

  /// The general chrome scrim — the window tone over the glass, heavy enough that
  /// content reads against it, thin enough that the desktop glows through.
  static let windowBackground = windowTone.opacity(0.55)

  /// Graph canvas fill — both canvases, the Graph overview and a project's. A scrim
  /// over the window's glass, a touch deeper than `windowBackground` so the ordering
  /// that survived the sidebar's move to glass survives this one too: sidebar bare
  /// glass, canvas a shade denser, cards and chrome on top.
  ///
  /// Heavier than the chrome scrim on purpose — this is the pane you *read*, and a
  /// canvas thin enough to show every wallpaper detail behind a tether is a canvas you
  /// squint at.
  static let canvasBackground = canvasTone.opacity(0.62)

  /// The canvas tone at full strength, for the few places that need to *occlude*
  /// rather than tint: the start marker's knockout ring, chips floating over the
  /// canvas. A translucent knockout isn't a knockout — the tether it exists to hide
  /// shows straight through it.
  static let canvasTone = Color(white: 0.095)

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
  /// Still *painted* rather than swapped for a second system material, but now over the
  /// window's glass instead of over paint: the gradient is a translucent scrim, so the
  /// strip picks up the same desktop glow as everything around it while keeping the
  /// lit-from-above shape a flat material can't express.
  ///
  /// It used to top out at 0.180 against a black terminal, and that was the grey band
  /// across the top of the window — the strip was the brightest thing on screen, which is
  /// exactly backwards for a row of tab labels. What separates it from the terminal now is
  /// `tabBarShadowLine` below it, not its own value.
  static let tabBarGloss = LinearGradient(
    colors: [
      Color(white: 0.145).opacity(0.66),
      Color(white: 0.122).opacity(0.62),
      Color(white: 0.106).opacity(0.58),
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
  ///
  /// Mixed from `windowTone`, not from the `windowBackground` scrim: veiling a *veil*
  /// compounds the two alphas and the inactive pane stops dimming at all.
  static let unfocusedPaneVeil = windowTone.opacity(0.35)

  /// How opaque a terminal's background is, handed to libghostty as `background-opacity`
  /// (`GhosttyAppearance`). The most solid surface in the window by design: it is the
  /// one you read code in, and it is the only pane whose contents graphcode doesn't
  /// control. Ghostty dims only the background — glyphs stay fully opaque — so this
  /// buys the glass without costing legibility.
  static let terminalBackgroundOpacity = 0.80

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

  /// A loop card, lit from above like the rest of the painted chrome.
  ///
  /// Paint rather than `.regularMaterial`, which is what cards used to be: at 106pt tall
  /// a card is four rows of small type, and glass let the wallpaper under it decide how
  /// much contrast a state pill and a mono meta row had. The canvas keeps its glass; the
  /// things you read on it hold still.
  static let loopCard = LinearGradient(
    colors: [
      Color(red: 0.173, green: 0.173, blue: 0.188),  // #2c2c30
      Color(red: 0.137, green: 0.137, blue: 0.149),  // #232326
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The same card with the warmth of the attention orange mixed into it — enough that a
  /// card wanting a human reads as a different object from across a zoomed-out graph,
  /// not so much that it becomes an alert.
  static let loopCardAttention = LinearGradient(
    colors: [
      Color(red: 0.188, green: 0.165, blue: 0.133),  // #302a22
      Color(red: 0.149, green: 0.133, blue: 0.125),  // #262220
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The workspace's loop bar — the band carrying the loop itself over its terminals.
  /// Lit like `tabBarGloss` and a step lighter, so the two strips read as one piece of
  /// chrome with the loop above the tabs rather than as two competing headers.
  static let loopBar = LinearGradient(
    colors: [
      Color(red: 0.141, green: 0.141, blue: 0.165),  // #24242a
      Color(red: 0.118, green: 0.118, blue: 0.133),  // #1e1e22
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The workspace's right rail and a pane header's focused tint.
  static let workspaceRail = Color(red: 0.114, green: 0.114, blue: 0.129)  // #1d1d21
  static let paneFocusTint = Color(red: 0.039, green: 0.518, blue: 1.0)  // #0a84ff

  /// A loop card's hairline. The attention variant is the orange itself: the border is
  /// the cheapest ring to read at 40% zoom, and at that size it is doing the work the
  /// pill's word does up close.
  static let loopCardBorder = Color.white.opacity(0.09)
  static let loopCardAttentionBorder = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.55)
}
