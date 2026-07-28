import SwiftUI

/// The window's chrome. graphcode is a dark tool that spends its life next to terminals,
/// so the window is a fixed dark gray keyed to the app icon's body rather than a system
/// material — materials shift value with the wallpaper behind them and go flat when the
/// window loses focus, which makes the graph canvas look like it changed color.
///
/// Three steps, darkest at the canvas: the sidebar sits *below* the window in value, the
/// canvas below that. The lit pane is the one you work in; the sidebar is the recess it
/// sits in, and the canvas is the depth the nodes float above.
///
/// Chrome is *painted* glossy — a gradient lit from above, a specular line on its top
/// edge, a shadow line where it meets the next pane (`sidebarGloss`, `tabBarGloss`). Not
/// a system material, for the reason above: glass would let the wallpaper tint the one
/// piece of chrome that has to hold still, and desaturate it the moment the window lost
/// focus.
enum Theme {
  /// Window and detail-pane fill — the icon body's lower gray.
  static let windowBackground = Color(red: 0.118, green: 0.125, blue: 0.141)

  /// Sidebar fill, a step *darker* than the window. It used to be a step lighter, which
  /// put the brightest chrome on the pane you look at least — a list of names you scan
  /// once and then ignore in favour of the canvas beside it. Sinking it below the window
  /// reads the way a native sidebar does: the content pane is what's lit, and the
  /// sidebar is the recess it sits in.
  static let sidebarBackground = Color(red: 0.098, green: 0.105, blue: 0.120)

  /// The gloss painted over `sidebarBackground` — lit from above and falling off down
  /// the pane, the same treatment `tabBarGloss` gives the tab strip, and painted for the
  /// same reason (see this file's header, and `tabBarGloss` itself). The range is
  /// deliberately narrower than the tab strip's: a sidebar is tall, so a gradient steep
  /// enough to read on a 40pt strip becomes an obvious vertical smear on a full-height
  /// pane. This one is meant to be felt rather than seen.
  static let sidebarGloss = LinearGradient(
    colors: [
      Color(red: 0.125, green: 0.133, blue: 0.149),
      Color(red: 0.102, green: 0.109, blue: 0.125),
      Color(red: 0.086, green: 0.092, blue: 0.106),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The specular line along the sidebar's top edge, where it meets the titlebar. Half
  /// the tab strip's, because this one runs the full height of the window next to it and
  /// a bright rule there would read as a border between two panes rather than as light.
  static let sidebarHighlight = Color.white.opacity(0.045)

  /// The shadow where the sidebar meets the detail pane. This is what actually separates
  /// them now that the sidebar is the darker of the two — a `NavigationSplitView`'s own
  /// divider is nearly invisible between two dark fills, and a hairline of black reads as
  /// the content pane casting into the recess rather than as a drawn line.
  static let sidebarEdgeShadow = Color.black.opacity(0.45)

  /// Graph canvas fill, the darkest step — white nodes read as lit against it.
  static let canvasBackground = Color(red: 0.075, green: 0.082, blue: 0.094)

  /// The canvas's notebook ruling. One step off `canvasBackground` and no further: the
  /// grid is there to give panning something to move against and to make the empty
  /// canvas read as a surface, so it has to lose to every edge and node drawn over it.
  static let canvasGridLine = Color(red: 0.129, green: 0.137, blue: 0.153)

  /// A loop workspace's tab bar fill — reads as its own chrome strip above the
  /// terminal, the same role `sidebarBackground` plays next to the canvas.
  static let tabBarBackground = Color(red: 0.145, green: 0.153, blue: 0.169)

  /// The gloss painted over `tabBarBackground`: lit from above, falling off to a shade
  /// darker than the flat fill at the bottom. Painted rather than a system material on
  /// purpose — for the reason at the top of this file, glass would desaturate the strip
  /// whenever the window lost focus and let the wallpaper tint it, so the one piece of
  /// chrome sitting against the terminal would be the one piece that never held still.
  static let tabBarGloss = LinearGradient(
    colors: [
      Color(red: 0.180, green: 0.188, blue: 0.208),
      Color(red: 0.145, green: 0.153, blue: 0.169),
      Color(red: 0.125, green: 0.133, blue: 0.149),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// The specular line along the strip's top edge — what actually sells "lit from
  /// above". Kept to one point: any thicker and it reads as a border.
  static let tabBarHighlight = Color.white.opacity(0.08)

  /// The shadow line where the strip meets the terminal, so the gloss ends on an edge
  /// rather than fading into the pane below it.
  static let tabBarShadowLine = Color.black.opacity(0.35)

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

  /// The selected tab's pill — lighter than `tabBarBackground` so it stands off the
  /// strip the way a real terminal app's active tab does, without reaching for the
  /// system accent color (this isn't a selection, it's "what's showing").
  static let tabSelectedBackground = Color(red: 0.235, green: 0.245, blue: 0.267)
}
