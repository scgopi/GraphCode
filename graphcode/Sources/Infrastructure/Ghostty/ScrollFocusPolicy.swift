import Foundation

/// Whether scrolling a terminal surface should give it the keyboard.
///
/// **This decides a frame rate, not just a focus ring.** libghostty runs its
/// `CVDisplayLink` — the clock every frame is paced against — only while a surface is
/// focused, and the two entry points disagree about it:
///
/// ```zig
/// setFocus(true)   => display_link.start()
/// setVisible(true) => if (visible and self.focused) start() else stop()
/// ```
///
/// With the link stopped, `hasVsync()` is false and `renderer.Thread.drawFrame` stops
/// deferring to the display, rendering change-driven instead: frames land when they are
/// ready rather than on the vertical blank. That is right for a window nobody is touching
/// and wrong for one being scrolled — and **scrolling never grants first responder on
/// macOS**, so an unfocused surface renders a whole gesture unpaced. Measured in the real
/// app, wheel events were arriving at surfaces whose window reported its first responder
/// as the window itself: nobody had the keyboard, so nothing was paced.
///
/// So a scroll claims focus, the same way a click already does. A pure decision function
/// because the alternative is a rule spelled out in `if` statements inside an `NSView`
/// that no test can reach.
enum ScrollFocusPolicy {
  /// What the window's first responder currently is, as far as this decision cares.
  enum Holder: Equatable {
    /// This very surface — nothing to do.
    case thisSurface
    /// Another terminal surface, typically the far half of a split.
    case anotherSurface
    /// Somewhere text is being typed: a rename field, a form. Never taken from.
    case textInput
    /// Anything else, including the window itself — AppKit's way of saying nobody.
    case somethingElse
  }

  /// Whether the scrolled surface should be made first responder.
  ///
  /// Taking it from `anotherSurface` is the deliberate part. Leaving the far half of a
  /// split focused keeps it paced and leaves the pane actually being scrolled rendering
  /// change-driven, which is the judder this exists to remove; and it is consistent with
  /// what a click already does, so the rule is "the pane you interact with is the focused
  /// pane" rather than "the pane you clicked".
  ///
  /// `textInput` is the one refusal. Scrolling a terminal while a rename field is open
  /// must not swallow the next keystroke — a scroll is not a commitment to type here, and
  /// silently moving the caret out of a field someone is editing is unrecoverable.
  ///
  /// A window that isn't key has no first responder worth moving; the click that makes it
  /// key will sort focus out.
  static func shouldClaimKeyboard(holder: Holder, windowIsKey: Bool) -> Bool {
    guard windowIsKey else { return false }
    switch holder {
    case .thisSurface, .textInput: return false
    case .anotherSurface, .somethingElse: return true
    }
  }
}
