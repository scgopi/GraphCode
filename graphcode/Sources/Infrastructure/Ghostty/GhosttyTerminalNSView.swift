import AppKit
import GhosttyKit

/// A real terminal surface, rendered by `GhosttyKit` itself — not a placeholder. This
/// is graphcode's own integration, adapted from the pattern in
/// `ThirdParty/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
/// (config construction, callback wiring) but deliberately not a port of it: no tabs,
/// splits, quick terminal, AppleScript, or window-management actions — this view is
/// always exactly one surface, matching how `LoopNodeDetailView` uses it (one sheet,
/// one node, one terminal).
///
/// Ghostty owns the PTY and the child process itself once given `command` — graphcode
/// doesn't spawn or read the process separately (see `GhosttyTerminalView` for how the
/// command line is built, usually a `zmx attach` wrapper so the session survives this
/// view closing).
final class GhosttyTerminalNSView: NSView {
  private(set) var surface: ghostty_surface_t!
  var onProcessExited: ((Bool) -> Void)?

  private var markedText: String = ""

  init(command: [String], workingDirectory: String?, environment: [String: String]) {
    super.init(frame: .zero)
    wantsLayer = true

    var config = ghostty_surface_config_new()
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
    config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    config.font_size = 0  // inherit default

    let envVars = environment.map { key, value in
      (key as NSString, value as NSString)
    }
    // Keep the env var C strings alive for the duration of surface creation.
    withExtendedLifetime(envVars) {
      var cEnvVars = envVars.map { key, value in
        ghostty_env_var_s(key: key.utf8String, value: value.utf8String)
      }
      cEnvVars.withUnsafeMutableBufferPointer { envVarsBuffer in
        config.env_vars = envVarsBuffer.baseAddress
        config.env_var_count = envVarsBuffer.count

        workingDirectory.withOptionalCString { workingDirectoryPtr in
          config.working_directory = workingDirectoryPtr
          commandLine(command).withCString { commandPtr in
            config.command = commandPtr
            self.surface = ghostty_surface_new(GhosttyRuntime.shared.app, &config)
          }
        }
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    if let surface {
      ghostty_surface_free(surface)
    }
  }

  /// Ghostty calls this when the surface's child process ends the session (or is
  /// force-closed). There's no exit-code plumbing in this callback, only whether a
  /// process is still alive — so "succeeded" here means "the surface closed because the
  /// command finished on its own," not a real exit status.
  func handleSurfaceClosed(processAlive: Bool) {
    onProcessExited?(!processAlive)
  }

  // MARK: - Sizing

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    guard let surface else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    ghostty_surface_set_size(
      surface, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface, let window else { return }
    ghostty_surface_set_content_scale(surface, window.backingScaleFactor, window.backingScaleFactor)
  }

  // MARK: - Focus

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    guard let surface else { return super.becomeFirstResponder() }
    ghostty_surface_set_focus(surface, true)
    return super.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    guard let surface else { return super.resignFirstResponder() }
    ghostty_surface_set_focus(surface, false)
    return super.resignFirstResponder()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    // `sendKeyEvent` already writes the key (including its text, for plain
    // characters) straight to the surface when it returns true — running
    // `interpretKeyEvents` afterward as well would redispatch that same text
    // through `insertText(_:replacementRange:)`, doubling every keystroke.
    // Only fall through to AppKit's IME path (dead keys, marked text, etc.)
    // when ghostty didn't already handle the event itself.
    guard !sendKeyEvent(event, action: GHOSTTY_ACTION_PRESS) else { return }
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    _ = sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
  }

  override func flagsChanged(with event: NSEvent) {
    _ = sendKeyEvent(event, action: GHOSTTY_ACTION_PRESS)
  }

  @discardableResult
  private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
    guard let surface else { return false }
    var keyEvent = ghostty_input_key_s()
    keyEvent.action = action
    keyEvent.keycode = UInt32(event.keyCode)
    keyEvent.mods = Self.mods(for: event.modifierFlags)

    guard let characters = event.characters, !characters.isEmpty else {
      return ghostty_surface_key(surface, keyEvent)
    }
    return characters.withCString { textPtr in
      keyEvent.text = textPtr
      return ghostty_surface_key(surface, keyEvent)
    }
  }

  private static func mods(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
    if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
    if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
    if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
    if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
    return ghostty_input_mods_e(rawValue: raw)
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
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

  private func sendMousePos(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    let scale = window?.backingScaleFactor ?? 1.0
    // Ghostty's origin is top-left; AppKit's is bottom-left.
    ghostty_surface_mouse_pos(
      surface,
      point.x * scale,
      (bounds.height - point.y) * scale,
      Self.mods(for: event.modifierFlags))
  }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }

    // A full-screen TUI (Claude Code, an editor, a pager) turns mouse reporting on, and
    // libghostty then reports each wheel tick to the program *at the surface's last
    // known cursor position* — it does not read the position off this event. A program
    // that only scrolls the region under the pointer therefore ignores ticks aimed at a
    // stale point, and because mouse reporting also suppresses Ghostty's own viewport
    // scrolling, the wheel does nothing at all. Stating the position first is what makes
    // the tick land where the pointer actually is.
    sendMousePos(event)

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

  private var trackingArea: NSTrackingArea?

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

extension GhosttyTerminalNSView: NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let surface else { return }
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty else { return }
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
    }
    markedText = ""
  }

  func setMarkedText(
    _ string: Any, selectedRange: NSRange, replacementRange: NSRange
  ) {
    markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
  }

  func unmarkText() {
    markedText = ""
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func markedRange() -> NSRange {
    markedText.isEmpty
      ? NSRange(location: NSNotFound, length: 0)
      : NSRange(location: 0, length: markedText.utf16.count)
  }
  func hasMarkedText() -> Bool { !markedText.isEmpty }
  func attributedSubstring(
    forProposedRange range: NSRange, actualRange: NSRangePointer?
  ) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let window else { return .zero }
    return window.convertToScreen(NSRect(origin: convert(.zero, to: nil), size: .zero))
  }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

/// Builds a shell-safe single command line string for `ghostty_surface_config_s.command`
/// (which takes one string, not an argv array) by quoting each argument.
private func commandLine(_ arguments: [String]) -> String {
  arguments.map { argument in
    "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }.joined(separator: " ")
}

extension Optional where Wrapped == String {
  fileprivate func withOptionalCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
    switch self {
    case .some(let value): return value.withCString(body)
    case .none: return body(nil)
    }
  }
}
