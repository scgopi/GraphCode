import Foundation

/// Whether a terminal surface that just entered the window should take the keyboard.
///
/// Switching loops replaces the whole workspace, and the incoming surface mounts while
/// the outgoing loop's surface — or the sidebar's table, mid-click — still holds first
/// responder. The old mount rule declined whenever *any* terminal held the keyboard, so
/// the outgoing surface blocked the incoming one; when the old pane then unmounted,
/// first responder fell back to the window and nobody claimed it. One click opened the
/// workspace, and a second click was needed before typing worked (issue #30).
///
/// The claim is evaluated one run-loop turn after the mount (see
/// `claimKeyboardOnMount`), so the outgoing pane has unmounted and the sidebar's `List`
/// has finished its selection dance by the time the holder is inspected. A pure decision
/// function for the same reason `ScrollFocusPolicy` is one: the alternative is a rule
/// spelled out in `if` statements inside an `NSView` that no test can reach.
enum MountFocusPolicy {
  /// What the window's first responder is by the time the deferred claim runs. Richer
  /// than `ScrollFocusPolicy.Holder` in exactly one place: a mount has to tell the
  /// legitimately focused pane apart from a leftover one, so `anotherSurface` splits
  /// into active and inactive.
  enum Holder: Equatable {
    /// This very surface — nothing to do.
    case thisSurface
    /// The surface the user is typing into — its tab showing, that tab's focused pane.
    /// A mounting sibling (the far half of a new split, another tab's pane) must not
    /// pull the keyboard out of it.
    case activeSurface
    /// A terminal nobody is looking at: the outgoing loop's pane, a hidden tab's.
    case inactiveSurface
    /// Somewhere text is being typed: a rename field, a form. Never taken from.
    case textInput
    /// Anything else — the window itself, the sidebar's table after the click that
    /// opened this workspace.
    case somethingElse
  }

  /// Whether the freshly mounted surface should be made first responder.
  ///
  /// Only the active surface claims — every tab of a workspace mounts at once, and the
  /// old rule's real purpose (the last surface to appear must not capture the keyboard
  /// for a shell that isn't on screen) survives as that gate.
  ///
  /// Taking from `somethingElse` is the fix: after a sidebar click that is the table,
  /// after a canvas click the window itself. Opening a workspace is always the user
  /// choosing this terminal, so focus follows the switch.
  ///
  /// No `windowIsKey` gate, unlike a scroll: a workspace opened while the window isn't
  /// key should be ready to type the moment it becomes key, and the mount claim never
  /// checked key status before.
  static func shouldClaimKeyboard(holder: Holder, surfaceIsActive: Bool) -> Bool {
    guard surfaceIsActive else { return false }
    switch holder {
    case .thisSurface, .activeSurface, .textInput: return false
    case .inactiveSurface, .somethingElse: return true
    }
  }
}
