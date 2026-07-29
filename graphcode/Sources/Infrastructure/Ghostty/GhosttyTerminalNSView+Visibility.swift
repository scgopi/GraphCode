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
}
