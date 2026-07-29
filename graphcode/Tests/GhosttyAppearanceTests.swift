import Foundation
import SwiftUI
import Testing

@testable import graphcode

/// The terminal's background has to be told to Ghostty through a file, and the file has to
/// say the same thing the rest of the window does. Both halves are easy to get silently
/// wrong — a malformed key is ignored, and a stale hex just looks like a design choice.
@Suite
struct GhosttyAppearanceTests {
  @Test
  func theTerminalIsToldTheWindowsOwnBackground() {
    #expect(GhosttyAppearance.hex(of: .black) == "000000")
    #expect(GhosttyAppearance.hex(of: .white) == "FFFFFF")
    // The point of the whole file: the terminal's color is the window's color, not a
    // second copy of it that can drift.
    #expect(
      GhosttyAppearance.hex(of: Theme.windowBackground)
        == GhosttyAppearance.hex(of: Theme.canvasBackground))
  }

  @Test
  func theConfigurationUsesGhosttysOwnKeyAndColorForm() {
    let text = GhosttyAppearance.configurationText(background: .black)
    // `background = 000000` — the key Ghostty reads, and a bare RRGGBB it accepts.
    #expect(text.contains("background = 000000"))
    #expect(text.hasSuffix("\n"))
  }

  @Test
  func writingLandsAFileGhosttyCanBeHandedByPath() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("ghostty-appearance-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = try #require(GhosttyAppearance.writeConfigurationFile(into: directory))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("background = "))
  }
}
