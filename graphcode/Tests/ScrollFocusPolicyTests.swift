import Testing

@testable import graphcode

/// Whether a scrolled terminal takes the keyboard — which is really whether its frames get
/// paced against the display.
///
/// The regression this guards is not a focus ring being in the wrong place. libghostty
/// stops its `CVDisplayLink` for any unfocused surface, so an unfocused terminal renders
/// change-driven rather than on the vertical blank, and scrolling one judders. Measured in
/// the running app, wheel events were arriving at surfaces whose window named *itself* as
/// first responder — nobody held the keyboard, so nothing was paced — and the fix has to
/// keep answering "yes" for that case.
@Suite
struct ScrollFocusPolicyTests {
  @Test("Nobody holding the keyboard means the scrolled surface takes it")
  func claimsFromNobody() {
    // `somethingElse` is the observed failure: `window.firstResponder === window`, AppKit's
    // way of saying no view has it. A surface scrolled in that state used to stay
    // unfocused and render the whole gesture unpaced.
    #expect(ScrollFocusPolicy.shouldClaimKeyboard(holder: .somethingElse, windowIsKey: true))
  }

  /// The deliberate half of the decision. Leaving the far pane focused would keep *it*
  /// paced while the pane actually being scrolled rendered change-driven, which is the
  /// judder this exists to remove.
  @Test("Scrolling the other half of a split moves focus to it")
  func claimsFromAnotherSurface() {
    #expect(ScrollFocusPolicy.shouldClaimKeyboard(holder: .anotherSurface, windowIsKey: true))
  }

  /// The one refusal, and the reason the decision isn't just "always claim". A scroll is
  /// not a commitment to type here; moving the caret out of a rename field someone is
  /// part-way through editing loses their next keystroke with nothing to undo.
  @Test("Text being edited keeps the keyboard")
  func neverTakesFromTextInput() {
    #expect(!ScrollFocusPolicy.shouldClaimKeyboard(holder: .textInput, windowIsKey: true))
  }

  @Test("A surface that already has the keyboard does nothing")
  func noOpWhenAlreadyFocused() {
    #expect(!ScrollFocusPolicy.shouldClaimKeyboard(holder: .thisSurface, windowIsKey: true))
  }

  /// Scrolling a background window shouldn't reach in and rearrange its focus — the click
  /// that makes it key will settle that, and doing it on a scroll would move focus in a
  /// window the user isn't in.
  @Test("A window that isn't key is left alone")
  func ignoresNonKeyWindows() {
    for holder: ScrollFocusPolicy.Holder in [
      .thisSurface, .anotherSurface, .textInput, .somethingElse,
    ] {
      #expect(!ScrollFocusPolicy.shouldClaimKeyboard(holder: holder, windowIsKey: false))
    }
  }
}
