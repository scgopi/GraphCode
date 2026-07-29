import AppKit
import Foundation
import GraphcodeKit
import SwiftUI

/// The terminal's own colors, so a loop's pane matches the rest of the window.
///
/// libghostty reads its configuration from files, not from the host app — there is no
/// "set the background color" call in `ghostty.h`. So graphcode writes a small config
/// file of its own and hands it to `ghostty_config_load_file` (see `GhosttyRuntime`).
///
/// Without it the terminal comes up in Ghostty's stock theme, whose background is a
/// blue-grey (`#282c34`). That is a perfectly good terminal color and completely wrong
/// here: the graph canvas is black, so opening a loop looked like it belonged to a
/// different app. The pane behind a terminal is the same surface as the canvas behind a
/// node, and it should read that way.
///
/// **Loaded before the user's own config, never after.** These are defaults, not
/// overrides — anyone who has set a Ghostty theme has said what they want their terminal
/// to look like, and graphcode is not entitled to overrule that just because it hosts the
/// surface.
enum GhosttyAppearance {
  /// The config file's contents.
  ///
  /// The color is derived from `Theme.windowBackground` rather than written out, because
  /// a hardcoded hex here is a copy that silently stops matching the day the window's
  /// color changes — which is exactly the mismatch this file exists to fix.
  static func configurationText(background: Color = Theme.windowBackground) -> String {
    """
    # Written by graphcode. Edited copies are overwritten on launch — put your own
    # settings in ~/.config/ghostty/config, which is loaded after this and wins.
    background = \(hex(of: background))

    """
  }

  /// Writes the file and returns its path, or nil if it couldn't be written — in which
  /// case the terminal simply keeps Ghostty's own colors, which is a cosmetic loss and
  /// not a reason to refuse to open a terminal at all.
  static func writeConfigurationFile(
    into directory: URL = SupportDirectory.url,
    background: Color = Theme.windowBackground
  ) -> String? {
    let url = directory.appendingPathComponent("ghostty-defaults.conf", isDirectory: false)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try configurationText(background: background).write(
        to: url, atomically: true, encoding: .utf8)
      return url.path
    } catch {
      return nil
    }
  }

  /// `RRGGBB`, which is the form Ghostty's `background` key takes.
  ///
  /// Converted through sRGB explicitly: a `Color` carries no components until it is
  /// resolved in some color space, and reading them in whatever space the display happens
  /// to use would put a different number in the file on a P3 screen than on an sRGB one.
  static func hex(of color: Color) -> String {
    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "000000" }
    let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
    return String(
      format: "%02X%02X%02X",
      channel(srgb.redComponent), channel(srgb.greenComponent), channel(srgb.blueComponent))
  }
}
