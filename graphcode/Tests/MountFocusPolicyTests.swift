import Testing

@testable import graphcode

/// Whether a surface that just entered the window takes the keyboard — which is really
/// whether opening a loop leaves you ready to type.
///
/// The regression this guards is issue #30: clicking a loop opened its workspace, but the
/// outgoing loop's still-mounted surface made the old mount rule decline, first responder
/// fell back to the window when that pane unmounted, and a second click was needed before
/// typing worked. The other direction is guarded too — the rule the old guard existed for
/// (a mounting surface must not capture the keyboard for a shell that isn't on screen)
/// has to keep holding.
@Suite
struct MountFocusPolicyTests {
  @Test("The active surface takes the keyboard from the outgoing loop's leftover pane")
  func claimsFromInactiveSurface() {
    #expect(
      MountFocusPolicy.shouldClaimKeyboard(holder: .inactiveSurface, surfaceIsActive: true))
  }

  /// The observed failure paths: after a sidebar click the holder is the `List`'s table,
  /// after a canvas click (or once the old pane unmounts) the window itself. Both mean
  /// the user just chose this terminal, so it claims.
  @Test("The active surface takes the keyboard from the sidebar table or the window")
  func claimsFromSomethingElse() {
    #expect(
      MountFocusPolicy.shouldClaimKeyboard(holder: .somethingElse, surfaceIsActive: true))
  }

  /// The rule the old unconditional-mount guard existed for, kept: every tab's surfaces
  /// mount at once, and only the pane the user is actually in may claim.
  @Test("An inactive surface never claims, whoever holds the keyboard")
  func inactiveSurfaceNeverClaims() {
    for holder: MountFocusPolicy.Holder in [
      .thisSurface, .activeSurface, .inactiveSurface, .textInput, .somethingElse,
    ] {
      #expect(!MountFocusPolicy.shouldClaimKeyboard(holder: holder, surfaceIsActive: false))
    }
  }

  @Test("The pane being typed into keeps the keyboard")
  func neverTakesFromActiveSurface() {
    #expect(
      !MountFocusPolicy.shouldClaimKeyboard(holder: .activeSurface, surfaceIsActive: true))
  }

  /// Same refusal as `ScrollFocusPolicy`, same reason: a workspace opening under a rename
  /// field must not swallow the next keystroke.
  @Test("Text being edited keeps the keyboard")
  func neverTakesFromTextInput() {
    #expect(!MountFocusPolicy.shouldClaimKeyboard(holder: .textInput, surfaceIsActive: true))
  }

  @Test("A surface that already has the keyboard does nothing")
  func noOpWhenAlreadyFocused() {
    #expect(!MountFocusPolicy.shouldClaimKeyboard(holder: .thisSurface, surfaceIsActive: true))
  }
}
