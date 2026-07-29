import AppKit
import Foundation
import GhosttyKit

/// The app's one terminal zoom: what every live surface is showing, what every new surface
/// starts at, and what a relaunch comes back to.
///
/// Shared rather than per-view because that is the whole point — see `TerminalFontZoom`
/// for why libghostty's own per-surface handling isn't enough. A zoom applied to one pane
/// of a split, or to the tab that happened to have focus, is not a preference; it's a
/// surface that no longer matches its neighbours.
///
/// `UserDefaults` rather than `GraphcodeSettings`, which is where `windowOpacity` and the
/// other cosmetic settings live: those are read by **`graphcoded`** out of a shared file,
/// and every write goes to disk as JSON. Zoom is neither — no part of the daemon cares how
/// big terminal text is, and holding ⌘− would rewrite that file once per keystroke. This
/// is app-local view state, so it lives where app-local view state lives.
@MainActor
final class TerminalFontZoomStore {
  static let shared = TerminalFontZoomStore()

  /// Zero, the value `UserDefaults.double(forKey:)` returns for a key that was never
  /// written, is also `TerminalFontZoom`'s "not zoomed" sentinel — so a first launch and a
  /// deliberate ⌘0 need no telling apart.
  private static let defaultsKey = "terminalFontZoomPoints"

  /// Every mounted surface, weakly — a terminal that closed shouldn't be kept alive by the
  /// zoom, and shouldn't have to remember to unregister itself from `deinit` either.
  private let surfaces = NSHashTable<GhosttyTerminalNSView>.weakObjects()

  private(set) var zoom: TerminalFontZoom

  private init() {
    let stored = UserDefaults.standard.double(forKey: Self.defaultsKey)
    zoom = TerminalFontZoom(
      configuredPoints: GhosttyRuntime.shared.configuredFontSize,
      points: stored > 0 ? stored : nil)
  }

  /// Takes a newly mounted surface under the app's zoom.
  ///
  /// It doesn't need the size applied: the view seeds `font_size` from
  /// `surfaceConfigFontSize` when it builds its config, which is the only way to get the
  /// grid right *before* the first frame. This is registration for later changes.
  func register(_ view: GhosttyTerminalNSView) {
    surfaces.add(view)
  }

  func apply(_ adjustment: TerminalFontZoom.Adjustment) {
    let updated = zoom.adjusted(adjustment)
    // A no-op at the clamp (⌘− at 1pt) shouldn't churn the defaults or re-push a size
    // every surface already has.
    guard updated != zoom else { return }
    zoom = updated
    UserDefaults.standard.set(zoom.storedPoints, forKey: Self.defaultsKey)
    for view in surfaces.allObjects {
      view.applyFontZoom(zoom)
    }
  }
}

extension GhosttyTerminalNSView {
  /// Puts the app's zoom on this surface.
  ///
  /// Through `ghostty_surface_binding_action` because there is no font-size setter in
  /// `ghostty.h` — the binding actions are the whole of libghostty's public surface for
  /// this, and `set_font_size:` is the only one that takes an absolute value rather than a
  /// delta. A delta would drift: surfaces are created at different times, and one that
  /// missed a step would stay a point off forever.
  func applyFontZoom(_ zoom: TerminalFontZoom) {
    guard let surface else { return }
    let action = zoom.bindingAction
    _ = action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
  }
}
