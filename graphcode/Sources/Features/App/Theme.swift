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

  /// A loop workspace's tab bar fill — reads as its own chrome strip above the
  /// terminal, the same role `sidebarBackground` plays next to the canvas.
  static let tabBarBackground = Color(red: 0.145, green: 0.153, blue: 0.169)

  /// The selected tab's pill — lighter than `tabBarBackground` so it stands off the
  /// strip the way a real terminal app's active tab does, without reaching for the
  /// system accent color (this isn't a selection, it's "what's showing").
  static let tabSelectedBackground = Color(red: 0.235, green: 0.245, blue: 0.267)
}
