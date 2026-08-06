import AppKit
import GhosttyKit

/// Whether a terminal surface is being looked at, and on which display — the two things
/// libghostty needs told to render it correctly, and neither of which graphcode told it
/// until this existed.
///
/// Split out of `GhosttyTerminalNSView` for file length, the same way the pointer handling
/// lives in `+Mouse`. These are `internal` rather than `private` only because Swift scopes
/// `private` to a file and their callers (`viewDidMoveToWindow`, `isVisible`'s observer)
/// stay in the main file alongside the stored state they cache into — an extension cannot
/// hold stored properties.
extension GhosttyTerminalNSView {

  /// Tells libghostty whether this surface is actually being looked at.
  ///
  /// Without this call libghostty assumes every surface is visible forever
  /// (`renderer.Thread`'s `visible` flag defaults to true), which means a hidden tab
  /// keeps its render thread at `.user_interactive` QoS rebuilding cells and drawing
  /// frames nobody sees — competing with the main thread and with the one surface that
  /// *is* on screen. Occluded, that thread drops to `.utility` and stops drawing
  /// entirely until it is told otherwise.
  ///
  /// Visible means both halves: this surface's tab is showing **and** the window itself
  /// isn't minimised or fully covered by another window. Upstream Ghostty drives the
  /// window half from `windowDidChangeOcclusionState`; so does this.
  func syncOcclusion() {
    guard let surface else { return }
    let windowIsVisible = window?.occlusionState.contains(.visible) ?? false
    let visible = isVisible && windowIsVisible
    guard lastOcclusion != visible else { return }
    lastOcclusion = visible
    ghostty_surface_set_occlusion(surface, visible)
    if visible && isActive {
      // libghostty's setVisible(true) only starts the display link when
      // self.focused is also true. If focus was lost during the occlusion
      // period (SwiftUI resigns it routinely), the link stays stopped and
      // the surface appears frozen despite being visible. Re-asserting
      // focus here restarts the link on de-occlusion.
      focusIfKeyboardIsOnAHiddenSurface()
    }
  }

  /// Tells libghostty which display this surface is on.
  ///
  /// Ghostty's macOS renderer paces its frames with a `CVDisplayLink`, created against
  /// the active displays and started immediately — but the link is only ever bound to a
  /// *particular* display by this call. Never making it leaves the link running at
  /// whatever display it defaulted to, so on a machine whose window is on a monitor with
  /// a different refresh rate than the default one (a 60Hz external beside a 120Hz
  /// ProMotion panel, either way round) every frame is delivered on the wrong cadence.
  /// That is judder, not merely wasted work: `drawFrame` defers to the display link when
  /// one is running, so the link *is* the frame clock.
  func syncDisplayID() {
    guard let surface, let screen = window?.screen else { return }
    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0
    guard lastDisplayID != displayID else { return }
    lastDisplayID = displayID
    ghostty_surface_set_display_id(surface, displayID)
  }

  /// Re-subscribes to the window this surface now belongs to.
  ///
  /// Per-window rather than app-wide because a surface outlives its parent view (see
  /// `TerminalSurfaceStore`) and can be re-parented into a different window over its
  /// life; the observers have to follow it rather than being registered once at birth.
  func observeWindow() {
    let center = NotificationCenter.default
    for observer in windowObservers { center.removeObserver(observer) }
    windowObservers.removeAll()
    guard let window else { return }
    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.syncOcclusion() }
      })
    windowObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.syncDisplayID()
          // A different screen may also be a different scale factor, and a point-sized
          // view moving between them never fires `setFrameSize`. Same reason
          // `viewDidChangeBackingProperties` re-syncs the size.
          self?.viewDidChangeBackingProperties()
        }
      })
  }

  /// Move the keyboard here if it is currently parked on a surface that isn't the active
  /// one — a hidden tab's, or the other half of this tab's split.
  ///
  /// It never takes focus *from* the active surface, so it can't fight a click: clicking
  /// the other pane makes that pane active first (see `onFocusRequested`), and this then
  /// agrees with the decision rather than making one.
  func focusIfKeyboardIsOnAHiddenSurface() {
    guard isActive, let window else { return }
    if let holder = window.firstResponder as? GhosttyTerminalNSView {
      guard !holder.isActive else { return }
    }
    window.makeFirstResponder(self)
  }

  /// Claims the keyboard for a surface that just entered the window, one run-loop turn
  /// later — the moment `viewDidMoveToWindow` fires, the outgoing loop's surface is
  /// still mounted (and still first responder), and a sidebar click's `List` selection
  /// hasn't finished moving first responder to its table. Deciding then reads a world
  /// that is about to change; a turn later both have settled and `MountFocusPolicy` can
  /// look at what actually holds the keyboard. See that type for the rule and issue #30
  /// for the second-click symptom this removes.
  func claimKeyboardOnMount() {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let window = self.window else { return }
        let holder: MountFocusPolicy.Holder
        switch window.firstResponder {
        case let responder as GhosttyTerminalNSView:
          holder =
            responder === self
            ? .thisSurface : responder.isActive ? .activeSurface : .inactiveSurface
        case is NSTextView:
          // `NSTextField` edits through a shared field editor, which is an `NSTextView`,
          // so this covers a rename field as well as a real text view.
          holder = .textInput
        default:
          holder = .somethingElse
        }
        guard
          MountFocusPolicy.shouldClaimKeyboard(holder: holder, surfaceIsActive: self.isActive)
        else { return }
        window.makeFirstResponder(self)
      }
    }
  }

  /// Take the keyboard back when nothing in the window is holding it.
  ///
  /// **This is a frame-pacing fix, not a keyboard one.** libghostty runs its
  /// `CVDisplayLink` — the clock every frame is paced against — only while a surface is
  /// focused, and the two entry points disagree about it:
  ///
  /// ```zig
  /// setFocus(true)   => display_link.start()
  /// setVisible(true) => if (visible and self.focused) start() else stop()
  /// ```
  ///
  /// With the link stopped, `hasVsync()` is false, and `renderer.Thread.drawFrame` stops
  /// deferring to the display — it renders "change-driven", so frames land when they are
  /// ready rather than on the vertical blank. That is right for a window nobody is
  /// touching and wrong for one being scrolled, and **scrolling never grants first
  /// responder on macOS**: a surface that has lost focus renders the entire gesture
  /// unpaced, which is what juddering scroll is.
  ///
  /// Focus really is lost, repeatedly, in ordinary use. Instrumented, wheel events arrive
  /// with `firstResponder = AppKitWindow` — the window itself, which is AppKit's way of
  /// saying nobody — while the surface is visible, on the showing tab, in the key window
  /// of the frontmost app. Something in the SwiftUI hierarchy resigns it and nothing
  /// claims it back, because the next thing that would (`focusIfKeyboardIsOnAHiddenSurface`
  /// via `updateNSView`) needs a SwiftUI update, and scrolling doesn't cause one.
  ///
  /// Claiming it here is not stealing. It happens only when the holder is the window
  /// itself; a real first responder — a text field, another surface — keeps it, so
  /// scrolling past a terminal can never take the keyboard out of something being typed
  /// in.
  /// Gives this surface the keyboard when it is scrolled, so libghostty paces its frames.
  ///
  /// See `ScrollFocusPolicy` for why a scroll decides a frame rate at all, and for what is
  /// and isn't taken from. Deliberately not gated on `isActive`: the measurement that
  /// found this showed wheel events arriving at surfaces reading `isActive=false`, so
  /// gating on it skipped the one surface being scrolled.
  ///
  /// The workspace is told as well as AppKit. They are two different records of the same
  /// fact — one drives the keyboard, the other the dimming and the filled cursor — and
  /// moving one without the other is how a split ends up with the veil over the pane you
  /// are typing into.
  func claimKeyboardForScroll() {
    guard let window else { return }
    let holder: ScrollFocusPolicy.Holder
    switch window.firstResponder {
    case let responder as GhosttyTerminalNSView:
      holder = responder === self ? .thisSurface : .anotherSurface
    case is NSTextView:
      // `NSTextField` edits through a shared field editor, which is an `NSTextView`, so
      // this covers a rename field as well as a real text view.
      holder = .textInput
    default:
      holder = .somethingElse
    }
    guard ScrollFocusPolicy.shouldClaimKeyboard(holder: holder, windowIsKey: window.isKeyWindow)
    else { return }
    guard window.makeFirstResponder(self) else { return }
    onFocusRequested?()
  }
}
