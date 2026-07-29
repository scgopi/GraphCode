import AppKit
import Testing

@testable import graphcode

/// The zoom is the app's, not each surface's — so the parts that are easy to get quietly
/// wrong are the ones that decide what a *new* surface starts at and what gets written to
/// disk, not the visible step itself. "Un-zoomed" and "zoomed to the default size" have to
/// stay distinguishable, because only the first still follows a `font-size` change.
@Suite
struct TerminalFontZoomTests {
  /// Ghostty's own macOS default, which graphcode then scales.
  private let configured: Double = 13
  private let zoom = TerminalFontZoom(configuredPoints: 13)

  /// Points don't survive `× 0.9` exactly — 13 × 0.9 is `11.700000000000001` — so sizes are
  /// compared the way the type itself compares them.
  private func isClose(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 0.001 }

  @Test
  func terminalsStartSmallerThanAStandaloneGhosttyWindow() {
    #expect(zoom.isDefault)
    #expect(isClose(zoom.resolvedPoints, 11.7))
    #expect(isClose(zoom.defaultPoints, configured * TerminalFontZoom.defaultScale))
  }

  @Test
  func aNewSurfaceIsBornAtTheDefaultRatherThanInheriting() {
    // Zero is libghostty's "use the configured size" sentinel. Sending it would open every
    // terminal at Ghostty's 13 and correct it to 11.7 only on the next keystroke.
    #expect(zoom.surfaceConfigFontSize != 0)
    #expect(isClose(Double(zoom.surfaceConfigFontSize), 11.7))
  }

  @Test
  func anUnzoomedTerminalStoresNothing() {
    // So that raising `font-size` in the user's own config still moves it.
    #expect(zoom.storedPoints == 0)
  }

  @Test
  func steppingIsAbsoluteAndStartsFromTheDefault() {
    let smaller = zoom.adjusted(.zoomOut)
    #expect(isClose(smaller.resolvedPoints, 10.7))
    #expect(!smaller.isDefault)
    // Absolute, not a delta: a surface created later must be able to land on the same size
    // without having seen the steps that got there.
    #expect(smaller.bindingAction == "set_font_size:10.70")
  }

  @Test
  func theActionNeverAsksGhosttyForItsOwnDefault() {
    // `reset_font_size` would restore Ghostty's 13, not graphcode's 11.7 — the two no
    // longer agree on what "default" means.
    #expect(zoom.bindingAction == "set_font_size:11.70")
    #expect(!zoom.bindingAction.contains("reset"))
  }

  @Test
  func returningToTheDefaultSizeIsTheSameAsNeverHavingZoomed() {
    // Otherwise ⌘−, ⌘= leaves every future surface pinned to a literal 11.7 while looking
    // exactly like an untouched terminal — and floating point guarantees the round trip
    // doesn't land on the same bits it started from.
    let roundTrip = zoom.adjusted(.zoomOut).adjusted(.zoomIn)
    #expect(roundTrip == zoom)
    #expect(roundTrip.isDefault)
  }

  @Test
  func resetClearsTheZoomRatherThanMatchingIt() {
    let reset = zoom.adjusted(.zoomIn).adjusted(.zoomIn).adjusted(.reset)
    #expect(reset.isDefault)
    #expect(reset.storedPoints == 0)
    #expect(isClose(reset.resolvedPoints, 11.7))
  }

  @Test
  func theDefaultTracksTheUsersOwnGhosttyFontSize() {
    // Someone with `font-size = 16` gets 14.4, not graphcode's idea of small.
    let larger = TerminalFontZoom(configuredPoints: 16)
    #expect(isClose(larger.resolvedPoints, 14.4))
    #expect(isClose(larger.adjusted(.zoomOut).resolvedPoints, 13.4))
    #expect(isClose(larger.adjusted(.zoomOut).adjusted(.reset).resolvedPoints, 14.4))
  }

  @Test
  func theSizeStaysInsideWhatLibghosttyWillAccept() {
    var tiny = TerminalFontZoom(
      configuredPoints: configured, points: TerminalFontZoom.minimumPoints)
    tiny = tiny.adjusted(.zoomOut)
    #expect(tiny.resolvedPoints == TerminalFontZoom.minimumPoints)
    // libghostty clamps too, so an unclamped value here wouldn't look wrong on screen —
    // it would leave the stored size disagreeing with the rendered one.
    let huge = TerminalFontZoom(configuredPoints: configured, points: 9_000)
    #expect(huge.resolvedPoints == TerminalFontZoom.maximumPoints)
    // And the scaled default itself can't fall below what libghostty accepts.
    #expect(TerminalFontZoom(configuredPoints: 1).resolvedPoints == TerminalFontZoom.minimumPoints)
  }

  @Test
  func theShortcutsAreTheOnesGhosttyItselfBinds() {
    #expect(TerminalFontZoom.adjustment(forKey: "=", modifiers: .command) == .zoomIn)
    // ⇧⌘= arrives as "+" on any layout, and is a key of its own on a German one.
    #expect(TerminalFontZoom.adjustment(forKey: "+", modifiers: [.command, .shift]) == .zoomIn)
    #expect(TerminalFontZoom.adjustment(forKey: "-", modifiers: .command) == .zoomOut)
    #expect(TerminalFontZoom.adjustment(forKey: "0", modifiers: .command) == .reset)
  }

  @Test
  func everythingElseBelongsToTheTerminal() {
    // A bare "-" is a character someone is typing.
    #expect(TerminalFontZoom.adjustment(forKey: "-", modifiers: []) == nil)
    // ⌃⌘− is not this shortcut, and swallowing it would eat a keystroke the shell wanted.
    #expect(TerminalFontZoom.adjustment(forKey: "-", modifiers: [.command, .control]) == nil)
    #expect(TerminalFontZoom.adjustment(forKey: "-", modifiers: [.command, .option]) == nil)
    #expect(TerminalFontZoom.adjustment(forKey: "k", modifiers: .command) == nil)
    #expect(TerminalFontZoom.adjustment(forKey: nil, modifiers: .command) == nil)
    // Caps lock is noise on a shortcut, not a different one.
    #expect(
      TerminalFontZoom.adjustment(forKey: "0", modifiers: [.command, .capsLock]) == .reset)
  }
}
