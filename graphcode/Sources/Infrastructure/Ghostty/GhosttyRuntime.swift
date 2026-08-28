import AppKit
import GhosttyKit
import GraphcodeKit
import os

/// The one process-wide `ghostty_app_t`. There's exactly one of these for the whole
/// app — graphcode never needs more than one `ghostty_surface_t` open at a time per
/// `LoopNodeDetail` sheet, so unlike Ghostty's own app (which manages tabs, splits,
/// and many windows sharing one `App`), this has no window/tab/split management at
/// all. Adapted from the setup in
/// `ThirdParty/ghostty/macos/Sources/Ghostty/Ghostty.App.swift` — that file's
/// `runtime_cfg` construction and callback dispatch pattern is the reference this
/// follows; everything here specific to tabs/splits/quick-terminal/AppleScript/menu
/// actions in that file is deliberately not ported, since graphcode's terminal is
/// always exactly one plain surface in a SwiftUI sheet.
final class GhosttyRuntime: @unchecked Sendable {
  static let shared = GhosttyRuntime()

  static let logger = Logger(subsystem: "dev.graphcode.app", category: "ghostty")

  let app: ghostty_app_t

  /// The size terminal text is at with nothing zoomed — Ghostty's own `font-size`, after
  /// the user's config has had its say.
  ///
  /// Read here rather than hardcoded in `TerminalFontZoom` because this is the only moment
  /// it can be: `ghostty_config_t` is freed at the end of this initializer, and there is
  /// no way to ask a surface or the app for it afterwards. Someone who set `font-size = 16`
  /// should zoom from 16 and land back on 16 at ⌘0, not on graphcode's idea of a default.
  let configuredFontSize: Double

  private init() {
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      fatalError("ghostty_init failed")
    }

    guard let config = ghostty_config_new() else {
      fatalError("ghostty_config_new failed")
    }
    // graphcode's own colors go in first so the user's config, loaded next, still wins —
    // see `GhosttyAppearance` for why the terminal needs told at all.
    if let defaults = GhosttyAppearance.writeConfigurationFile() {
      ghostty_config_load_file(config, defaults)
    }
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)

    // After finalize, so this is the value the surfaces will actually be built with. The
    // fallback is Ghostty's own macOS default (`src/config/Config.zig`) for the case where
    // the C getter doesn't support the key — it would only cost the zoom its starting
    // point, which is no reason to refuse to open a terminal.
    var fontSize: Float = 0
    let fontSizeKey = "font-size"
    let read = ghostty_config_get(
      config, &fontSize, fontSizeKey, UInt(fontSizeKey.utf8.count))
    configuredFontSize = read && fontSize > 0 ? Double(fontSize) : 13

    var runtimeConfig = ghostty_runtime_config_s(
      userdata: nil,
      supports_selection_clipboard: false,
      wakeup_cb: { _ in GhosttyRuntime.wakeup() },
      action_cb: { _, target, action in
        GhosttyRuntime.handleAction(target: target, action: action)
      },
      read_clipboard_cb: { userdata, _, state in
        GhosttyRuntime.readClipboard(userdata, state: state)
      },
      confirm_read_clipboard_cb: { userdata, string, state, _ in
        GhosttyRuntime.confirmReadClipboard(userdata, string: string, state: state)
      },
      write_clipboard_cb: { userdata, _, content, len, _ in
        GhosttyRuntime.writeClipboard(userdata, content: content, len: len)
      },
      close_surface_cb: { userdata, processAlive in
        GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
      }
    )

    guard let app = ghostty_app_new(&runtimeConfig, config) else {
      fatalError("ghostty_app_new failed")
    }
    self.app = app
    ghostty_config_free(config)
    observeAppActivation()
  }

  func tick() {
    ghostty_app_tick(app)
  }

  /// Keeps libghostty told whether graphcode is the frontmost app.
  ///
  /// This is separate from `ghostty_surface_set_focus`, which says *which surface* holds
  /// the keyboard — this says whether the app holds it at all. libghostty picks a
  /// renderer thread QoS class from it: an unfocused-but-visible surface renders at
  /// `.user_initiated` rather than `.user_interactive`, so a graphcode window sitting
  /// behind someone's editor stops competing with it in the top priority band. Never
  /// setting it left every surface claiming to be foreground for the app's whole life.
  ///
  /// Seeded from `NSApp.isActive` rather than assumed true: the app can come up in the
  /// background — opened by `launchd`, or restored behind another app.
  private func observeAppActivation() {
    ghostty_app_set_focus(app, NSApp.isActive)
    let center = NotificationCenter.default
    center.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      ghostty_app_set_focus(self.app, true)
    }
    center.addObserver(
      forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      ghostty_app_set_focus(self.app, false)
    }
  }

  // MARK: - Runtime callbacks
  //
  // These receive whichever userdata libghostty considers relevant per call site —
  // for wakeup that's app-level (unused here beyond dispatching a tick), for
  // clipboard/close it's the surface's own userdata, which graphcode sets to its
  // owning `GhosttyTerminalNSView` (see that file's `ghostty_surface_config_s`
  // construction).

  /// One in-flight main-thread tick at a time. See `TickCoalescer` for why.
  private static let tickCoalescer = TickCoalescer()

  private static func wakeup() {
    // May be called from any thread; ghostty_app_tick must happen on the main thread.
    guard tickCoalescer.claim() else { return }
    DispatchQueue.main.async {
      // Released *before* the tick, not after: a wakeup that arrives while this one is
      // running has to be able to queue the next tick, or its work waits for the next
      // unrelated wakeup. An extra tick is free; a dropped one is a stalled surface.
      GhosttyRuntime.tickCoalescer.release()
      GhosttyRuntime.shared.tick()
    }
  }

  private static func view(from userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalNSView? {
    guard let userdata else { return nil }
    return Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
  }

  /// The one action graphcode handles: a ⌘-clicked link. Everything else returns
  /// false and libghostty's defaults apply — the same posture as before, just no
  /// longer for URLs, because who opens a link is where remote sign-ins are won.
  ///
  /// A CLI in a remote session (`az login`, `claude`, `codex login`) prints an auth
  /// URL whose OAuth callback is a localhost port on *that* machine; the browser is
  /// on this one. Before opening the browser, any loopback port the URL names
  /// (`AuthCallbackPorts` — the URL's own authority, or a `redirect_uri` parameter)
  /// is forwarded into the clicked surface's remote host, so the redirect the
  /// provider makes lands on the CLI that is waiting for it.
  ///
  /// May be called off the main thread; `remoteLocation` is a plain property written
  /// on main during `apply` — a torn read costs one un-forwarded click, not a crash.
  ///
  /// Everything that is not a scheme-carrying `.unknown` URL returns false, keeping
  /// libghostty's opener byte-identical to pre-interception behavior: `.text`/`.html`
  /// come from scrollback dumps and open in an editor there, and a clicked *file
  /// path* (Ghostty resolves `./relative` links to bare absolute paths) parses as a
  /// scheme-less `URL` that `NSWorkspace` won't open but `/usr/bin/open` will. Both
  /// click gestures land here — ⇧ only bypasses a TUI's mouse capture — so these
  /// guards are what keep ⌘⇧-click on local folders exactly as it was.
  static func handleAction(
    target: ghostty_target_s, action: ghostty_action_s
  ) -> Bool {
    guard action.tag == GHOSTTY_ACTION_OPEN_URL else { return false }
    let openUrl = action.action.open_url
    guard openUrl.kind == GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN else { return false }
    guard let urlPointer = openUrl.url, openUrl.len > 0 else { return false }
    let urlString = String(
      decoding: UnsafeRawBufferPointer(start: urlPointer, count: Int(openUrl.len)),
      as: UTF8.self)
    guard let url = URL(string: urlString), url.scheme != nil else { return false }
    if target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
      let location = view(from: ghostty_surface_userdata(surface))?.remoteLocation
    {
      for port in AuthCallbackPorts.extract(fromURLString: urlString) {
        Task { await RemoteAuthPortForwarder.shared.ensureForwarding(port: port, to: location) }
      }
    }
    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    return true
  }

  private static func readClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    state: UnsafeMutableRawPointer?
  ) -> Bool {
    guard let view = view(from: userdata) else { return false }
    guard let string = NSPasteboard.general.string(forType: .string) else { return false }
    string.withCString { ptr in
      ghostty_surface_complete_clipboard_request(view.surface, ptr, state, false)
    }
    return true
  }

  private static func confirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    string: UnsafePointer<CChar>?,
    state: UnsafeMutableRawPointer?
  ) {
    // No confirmation UI (yet) — auto-confirm so paste actually completes. Ghostty's
    // own app shows a dialog here for untrusted-content safety; graphcode nodes
    // aren't running arbitrary shared terminals the way a general-purpose terminal
    // app is, so this is a reasonable simplification for now, not an oversight.
    guard let view = view(from: userdata), let string else { return }
    ghostty_surface_complete_clipboard_request(view.surface, string, state, true)
  }

  private static func writeClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    len: Int
  ) {
    guard view(from: userdata) != nil, let content, len > 0 else { return }
    for index in 0..<len {
      let item = content[index]
      guard let mime = item.mime, String(cString: mime) == "text/plain" else { continue }
      guard let data = item.data else { continue }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(String(cString: data), forType: .string)
      return
    }
  }

  private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    guard let view = view(from: userdata) else { return }
    DispatchQueue.main.async { view.handleSurfaceClosed(processAlive: processAlive) }
  }
}
