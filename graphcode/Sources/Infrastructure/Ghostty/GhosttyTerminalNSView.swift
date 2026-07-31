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

  /// Called when the user clicks into this surface, so the workspace can record which
  /// pane of a split they meant.
  ///
  /// Hung off mouse down rather than `becomeFirstResponder()`, which would seem the
  /// natural place: that also fires while surfaces are being mounted, and with several
  /// panes coming up at once whichever one happened to win the race would report itself
  /// as the user's choice. A click is the only signal that can't be anything else.
  var onFocusRequested: (() -> Void)?

  private var markedText: String = ""

  // The visibility caches, stored here rather than in `+Visibility` for the reason
  // `trackingArea` is stored here rather than in `+Mouse`: an extension cannot hold stored
  // properties. Not `private` for the same reason — Swift scopes that to a file.

  /// The last value handed to `ghostty_surface_set_occlusion`, so a resize or a window
  /// notification that doesn't actually change visibility costs nothing. `nil` until the
  /// first sync, so the first one always lands.
  var lastOcclusion: Bool?

  /// The last display id handed to libghostty, for the same reason.
  var lastDisplayID: UInt32?

  /// Wheel deltas accumulated between flushes — `scrollWheel` (in `+Mouse`) coalesces
  /// rather than forwarding per event; see there for the escape-sequence-fragmentation
  /// story. Stored here because an extension can't hold stored properties, and not
  /// `private` because Swift scopes that to a file.
  var pendingScrollDeltaX: CGFloat = 0
  var pendingScrollDeltaY: CGFloat = 0
  var pendingScrollMods: ghostty_input_scroll_mods_t = 0
  var scrollFlushScheduled = false

  var windowObservers: [NSObjectProtocol] = []

  init(command: [String], workingDirectory: String?, environment: [String: String]) {
    super.init(frame: .zero)
    wantsLayer = true

    var config = ghostty_surface_config_new()
    config.userdata = Unmanaged.passUnretained(self).toOpaque()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(
      macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
    config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    // The app's zoom, so a terminal opened after someone pressed ⌘− comes up at the size
    // every other terminal is already at — and an un-zoomed one at graphcode's own default
    // rather than Ghostty's, which is why this is never the "inherit" sentinel of zero it
    // used to be. Set here rather than applied after creation so the cell grid is right on
    // the first frame instead of reflowing once the surface is on screen.
    config.font_size = TerminalFontZoomStore.shared.zoom.surfaceConfigFontSize

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

    // Weakly held, so this is registration for later zooms only — nothing to unregister
    // when the terminal closes.
    TerminalFontZoomStore.shared.register(self)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
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
    syncSurfaceSize()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface, let window else { return }
    let scale = window.backingScaleFactor
    // The layer's own scale first: libghostty renders into this view's backing layer,
    // and AppKit does not push backing changes down to it on its own — so after a drag
    // to a display of a different scale the Metal drawable kept the old density and
    // the terminal came back blurred or the wrong size. Wrapped to suppress the
    // implicit animation, which would otherwise visibly "zoom" the glyphs into place.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.contentsScale = scale
    CATransaction.commit()
    ghostty_surface_set_content_scale(surface, scale, scale)
    // And the size again, which is the half that was missing. `ghostty_surface_set_size`
    // takes **backing pixels**, so dragging a window between displays of different scale
    // changes the surface's pixel dimensions while its *point* size is untouched — and a
    // point size that didn't change means `setFrameSize` never fires. libghostty was left
    // with the new scale and the old pixel count, so it laid out its cell grid against
    // dimensions that no longer existed and the text came back at the wrong size.
    syncSurfaceSize()
  }

  /// Tells libghostty how big the surface is, in the backing pixels it measures in.
  ///
  /// One implementation for both callers on purpose: the size and the scale are two halves
  /// of the same fact, and the bug this fixes was them being updated in different places.
  private func syncSurfaceSize() {
    guard let surface else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    ghostty_surface_set_size(
      surface, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
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

  /// Whether this surface is *the* one the user is typing into — its tab is showing and
  /// it is that tab's focused pane. Drives the keyboard, not the renderer: the other half
  /// of a split is inactive but very much visible. See `isVisible`.
  var isActive: Bool = false

  /// Whether this surface's tab is the one on screen. Every tab's surfaces stay mounted
  /// at once (see `LoopWorkspaceView`), so "is in the window" says nothing about "is the
  /// one the user is looking at" — this is what tells them apart, and it is what
  /// libghostty needs to know. Both panes of a split are visible; only one is active.
  var isVisible: Bool = false {
    didSet { syncOcclusion() }
  }

  /// Owned here rather than in `+Mouse` because an extension cannot hold stored
  /// properties; `updateTrackingAreas` alongside the rest of the mouse code uses it.
  var trackingArea: NSTrackingArea?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeWindow()
    syncDisplayID()
    // A surface that has left the view hierarchy is neither showing nor the pane anyone is
    // typing in, and nothing else will say so: `GhosttyTerminalView.apply(to:)` only runs
    // for surfaces SwiftUI still has mounted, and since `TerminalSurfaceStore` began
    // outliving those views an unmounted one kept whatever it was last told. A stale
    // `isActive` then let a surface belonging to a loop nobody is looking at behave as the
    // focused pane.
    if window == nil {
      isActive = false
      isVisible = false
    }
    syncOcclusion()
    guard window != nil else { return }
    // Only claim focus if no other terminal already holds it. Mounting used to take it
    // unconditionally, so with several tabs alive the last surface to appear captured
    // the keyboard no matter which tab was showing — typing, and prefixes like tmux's
    // ctrl+a, went to a shell that wasn't on screen.
    guard !(window?.firstResponder is GhosttyTerminalNSView) else { return }
    window?.makeFirstResponder(self)
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    // Zoom first, and never forwarded. libghostty binds these same keys itself, so letting
    // the event through as well would apply the step twice — and would apply the second
    // one to this surface alone, which is the per-surface behaviour the app-wide zoom
    // exists to replace. See `TerminalFontZoom`.
    if let adjustment = zoomAdjustment(for: event) {
      TerminalFontZoomStore.shared.apply(adjustment)
      return
    }
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
    // Swallowed to match the press. A release whose press the surface never saw is exactly
    // the sort of thing the kitty keyboard protocol reports to the program on the other
    // end, and a shell being told about a key nobody pressed is worse than being told
    // nothing.
    guard zoomAdjustment(for: event) == nil else { return }
    _ = sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
  }

  /// Whether this keystroke is one of the app's zoom shortcuts. See `TerminalFontZoom` for
  /// the mapping, and for why graphcode answers them rather than libghostty.
  private func zoomAdjustment(for event: NSEvent) -> TerminalFontZoom.Adjustment? {
    TerminalFontZoom.adjustment(
      forKey: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
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
    // macOS won't tell us which modifiers were consumed producing the text, so use
    // upstream Ghostty's long-standing heuristic: control and command never contribute
    // to translation, everything else did.
    keyEvent.consumed_mods = Self.mods(for: event.modifierFlags.subtracting([.control, .command]))
    keyEvent.composing = false

    // `characters` and friends are only meaningful on key events — `flagsChanged` comes
    // through here too, and asking a modifier event for its characters is not valid.
    let isKeyEvent = event.type == .keyDown || event.type == .keyUp
    // What the key would type with nothing held. Ghostty encodes control sequences
    // itself from this — without it, ctrl+<key> has no base character to work from and
    // a prefix like tmux's ctrl+a never arrives as 0x01.
    let unshifted = isKeyEvent ? event.characters(byApplyingModifiers: []) : nil
    if let scalar = unshifted?.unicodeScalars.first {
      keyEvent.unshifted_codepoint = scalar.value
    }

    // Text is deliberately withheld for control characters: Ghostty's own key encoder
    // owns that mapping, and handing it a pre-encoded control byte *and* the ctrl
    // modifier makes it encode the wrong thing (upstream hit this with ctrl+enter).
    guard isKeyEvent, let text = Self.text(for: event),
      let firstByte = text.utf8.first, firstByte >= 0x20
    else {
      return ghostty_surface_key(surface, keyEvent)
    }
    return text.withCString { textPtr in
      keyEvent.text = textPtr
      return ghostty_surface_key(surface, keyEvent)
    }
  }

  /// The text a key event should contribute, mirroring upstream Ghostty's
  /// `NSEvent.ghosttyCharacters`.
  private static func text(for event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      // A lone control character: hand back what the key types *without* control, and
      // let Ghostty apply the control encoding itself.
      if scalar.value < 0x20 {
        return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
      }
      // Function keys arrive as private-use codepoints; they are keys, not text, and
      // must not be written into the terminal as characters.
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
    }
    return characters
  }

  /// Shared with the mouse handling in `GhosttyTerminalNSView+Mouse`, hence not
  /// `private` — Swift's `private` is file-scoped and that lives in another file.
  static func mods(for flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = 0
    if flags.contains(.shift) { raw |= UInt32(GHOSTTY_MODS_SHIFT.rawValue) }
    if flags.contains(.control) { raw |= UInt32(GHOSTTY_MODS_CTRL.rawValue) }
    if flags.contains(.option) { raw |= UInt32(GHOSTTY_MODS_ALT.rawValue) }
    if flags.contains(.command) { raw |= UInt32(GHOSTTY_MODS_SUPER.rawValue) }
    if flags.contains(.capsLock) { raw |= UInt32(GHOSTTY_MODS_CAPS.rawValue) }
    return ghostty_input_mods_e(rawValue: raw)
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
