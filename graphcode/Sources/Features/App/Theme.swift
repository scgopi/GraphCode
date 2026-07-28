import SwiftUI

/// The window's chrome. graphcode is a dark tool that spends its life next to terminals,
/// so the window is a fixed dark gray keyed to the app icon's body rather than a system
/// material — materials shift value with the wallpaper behind them and go flat when the
/// window loses focus, which makes the graph canvas look like it changed color.
///
/// Three steps, darkest at the canvas: the sidebar reads as chrome, the canvas as depth
/// the nodes float above.
enum Theme {
  /// Window and detail-pane fill — the icon body's lower gray.
  static let windowBackground = Color(red: 0.118, green: 0.125, blue: 0.141)

  /// Sidebar fill, a step lighter than the window so the split divider needs no help.
  static let sidebarBackground = Color(red: 0.145, green: 0.153, blue: 0.169)

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
