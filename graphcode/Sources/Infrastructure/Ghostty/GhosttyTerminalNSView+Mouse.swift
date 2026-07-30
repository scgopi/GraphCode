import AppKit
import GhosttyKit

/// Pointer input for a terminal surface — position, buttons, drags, and the wheel.
///
/// Split out of `GhosttyTerminalNSView` for file length; it is one view's behaviour, and
/// the reasoning that matters lives on the individual methods. The one thing worth
/// knowing up front is the API's unit asymmetry: `ghostty_surface_set_size` takes
/// backing pixels, `ghostty_surface_mouse_pos` takes points. See `sendMousePos`.
extension GhosttyTerminalNSView {
  override func mouseDown(with event: NSEvent) {
    // Before forwarding, not after: the click is what makes this the focused pane, and
    // the terminal's own handling of it (placing a selection anchor) belongs to a pane
    // that is already focused.
    onFocusRequested?()
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
  }

  override func mouseUp(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
  }

  override func rightMouseDown(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
  }

  override func rightMouseUp(with event: NSEvent) {
    sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
  }

  /// Middle-click and the rest. Middle-click is paste-from-selection in most terminal
  /// programs, and a TUI that tracks the mouse expects to hear about these buttons.
  override func otherMouseDown(with event: NSEvent) {
    sendMouseButton(
      event, state: GHOSTTY_MOUSE_PRESS, button: Self.button(for: event.buttonNumber))
  }

  override func otherMouseUp(with event: NSEvent) {
    sendMouseButton(
      event, state: GHOSTTY_MOUSE_RELEASE, button: Self.button(for: event.buttonNumber))
  }

  private static func button(for buttonNumber: Int) -> ghostty_input_mouse_button_e {
    switch buttonNumber {
    case 0: GHOSTTY_MOUSE_LEFT
    case 1: GHOSTTY_MOUSE_RIGHT
    case 2: GHOSTTY_MOUSE_MIDDLE
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  private func sendMouseButton(
    _ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e
  ) {
    guard let surface else { return }
    ghostty_surface_mouse_button(surface, state, button, Self.mods(for: event.modifierFlags))
  }

  override func mouseMoved(with event: NSEvent) {
    sendMousePos(event)
  }

  override func mouseDragged(with event: NSEvent) {
    sendMousePos(event)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    // Re-establish the position on entry: `mouseExited` parks it outside the viewport,
    // and libghostty gates a lot of mouse behaviour on the position being inside.
    sendMousePos(event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    // A drag that leaves the view is still a drag — selection has to keep extending, so
    // only park the position when no button is down.
    guard NSEvent.pressedMouseButtons == 0, let surface else { return }
    ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(for: event.modifierFlags))
  }

  override func rightMouseDragged(with event: NSEvent) {
    sendMousePos(event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    sendMousePos(event)
  }

  /// Position in **points**, not backing pixels.
  ///
  /// This is the API's one asymmetry and it was the bug behind wrong text selection and
  /// misplaced mouse reports: `ghostty_surface_set_size` wants backing pixels, but
  /// `ghostty_surface_mouse_pos` wants points. Scaling this by `backingScaleFactor`
  /// therefore reported every click, drag and wheel tick at twice its real position on a
  /// Retina display — selections started in the wrong cell, and a tmux pane or TUI
  /// hit-testing the report got a point that wasn't under the pointer. Both upstream
  /// Ghostty's surface view and supacode pass the unscaled point; so does this now.
  private func sendMousePos(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    // Ghostty's origin is top-left; AppKit's is bottom-left.
    ghostty_surface_mouse_pos(
      surface, point.x, bounds.height - point.y, Self.mods(for: event.modifierFlags))
  }

  /// Wheel and trackpad scroll, forwarded and nothing else.
  ///
  /// There is deliberately no `sendMousePos` here, and there used to be — on the theory
  /// that libghostty reports a wheel tick at the surface's last known cursor position, so
  /// restating it costs nothing.
  ///
  /// **This was removed as a correctness fix, not a speed one.** It was first argued for
  /// on performance grounds: every wheel event entered `cursorPosCallback`, which takes
  /// the renderer state mutex. Benchmarked against a live surface, 20k events per arm, it
  /// made no difference at all — 1272ns vs 1257ns per event with mouse reporting off, and
  /// 180ns vs 175ns with it on. The hyperlink-hover work that would have cost something is
  /// skipped while the pointer is stationary, which it is throughout a scroll. Recorded
  /// here so the claim is not re-invented.
  ///
  /// What it did do is real: under a TUI with motion reporting on, it wrote a spurious
  /// mouse-*motion* report to the PTY per wheel tick, so the program on the other end was
  /// told the pointer had moved when it had not.
  ///
  /// The position it was restating was already current: `mouseMoved`/`mouseEntered`
  /// tracking (`.activeAlways`, see `updateTrackingAreas`) keeps it so. Neither upstream
  /// Ghostty's surface view nor supacode's sends a position from `scrollWheel`, and this
  /// no longer does either.
  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    // Before the scroll is forwarded, because it decides whether the frames this gesture
    // produces are paced against the display at all. See `ScrollFocusPolicy`.
    claimKeyboardForScroll()

    var deltaX = event.scrollingDeltaX
    var deltaY = event.scrollingDeltaY
    let precise = event.hasPreciseScrollingDeltas
    if precise {
      // Matching upstream Ghostty's own surface view. Trackpad deltas are in pixels and
      // the core only emits a line once they accumulate past a cell height, so at 1x a
      // slow drag can accumulate for a long time before anything moves.
      deltaX *= 2
      deltaY *= 2
    }

    ghostty_surface_mouse_scroll(
      surface, deltaX, deltaY, Self.scrollMods(precise: precise, momentum: event.momentumPhase))
  }

  /// `input.ScrollMods` packed into the byte libghostty expects: precision in bit 0, the
  /// momentum phase in bits 1–3 (see `src/input/mouse.zig`). Inertial frames arriving
  /// labelled `.none` are indistinguishable from real ones, which is not what a terminal
  /// wants to know about a flick.
  private static func scrollMods(
    precise: Bool, momentum: NSEvent.Phase
  ) -> ghostty_input_scroll_mods_t {
    let phase: Int32
    switch momentum {
    case .began: phase = 1
    case .stationary: phase = 2
    case .changed: phase = 3
    case .ended: phase = 4
    case .cancelled: phase = 5
    case .mayBegin: phase = 6
    default: phase = 0
    }
    return ghostty_input_scroll_mods_t((precise ? 1 : 0) | (phase << 1))
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [
        .mouseEnteredAndExited,
        .mouseMoved,
        .inVisibleRect,
        // `.activeAlways`, not `.activeInKeyWindow`, for the same reason upstream
        // Ghostty uses it: a surface has to keep reporting the mouse even when it isn't
        // focused or its window isn't key. Under `.activeInKeyWindow` the pointer could
        // move across a pane without a single position update, leaving every subsequent
        // wheel tick reported at wherever it was last seen.
        .activeAlways,
      ],
      owner: self)
    addTrackingArea(area)
    trackingArea = area
  }
}
