import AppKit
import Foundation

/// How big terminal text is, and the arithmetic that moves it.
///
/// libghostty already binds ⌘=/⌘−/⌘0 and handles them perfectly well — but it handles them
/// *per surface*, and tells the host nothing about the size it landed on. graphcode keeps
/// several terminals alive at once (every tab stays mounted, a split has two) and makes new
/// ones constantly, so a zoom that only reached the surface the keystroke happened to land
/// on would leave you re-zooming each tab, and each tab again after a relaunch.
///
/// So graphcode owns the number instead: `GhosttyTerminalNSView` takes those keys before
/// libghostty sees them, and `TerminalFontZoomStore` drives every live surface from this
/// one value with `set_font_size`. That is what makes zooming out once mean "terminal text
/// is this size" rather than "this one pane is smaller".
///
/// A value with the arithmetic on it, for the same reason as `CanvasTransform`: the
/// clamping, the step, and the default-versus-zoomed distinction are all easy to get
/// subtly wrong, and all three are needed in three different places (the keystroke, a new
/// surface's config, the stored preference).
struct TerminalFontZoom: Equatable {
  /// What libghostty will accept. Its font-size actions clamp to 1…255 points
  /// (`ThirdParty/ghostty/src/Surface.zig`, the `increase/decrease/set_font_size` cases),
  /// silently pinning anything outside rather than refusing it — so a value that leaves
  /// here out of range would make the stored size and the rendered size disagree.
  static let minimumPoints: Double = 1
  static let maximumPoints: Double = 255

  /// One press of ⌘= or ⌘−. A single point, which is exactly what Ghostty's own bindings
  /// do (`ThirdParty/ghostty/src/config/Config.zig`): this replaces those bindings, and it
  /// shouldn't feel like a different terminal because of it.
  static let step: Double = 1

  /// graphcode's terminals start a little smaller than a standalone Ghostty window would —
  /// 0.9 of the configured `font-size`, so 11.7pt against Ghostty's macOS default of 13.
  ///
  /// A fraction rather than a point size, so it still tracks the user's own config: someone
  /// who set `font-size = 16` gets 14.4 here, not graphcode's idea of small. A terminal
  /// here shares its window with the sidebar, the tab strip and a split's other pane, and
  /// wants to fit more rows than a window that is nothing but terminal.
  static let defaultScale: Double = 0.9

  /// Distances below this count as the same size. Two steps that cancel out are not
  /// bit-identical in floating point once `defaultScale` is in play (13 × 0.9 is not a
  /// number a `Double` holds exactly), and a hair's difference would leave a terminal
  /// looking untouched while quietly pinning every surface made after it. Far inside a
  /// point, far outside the noise.
  private static let tolerance: Double = 0.001

  /// The size with nothing zoomed: `defaultScale` of Ghostty's `font-size`, after the
  /// user's config has had its say.
  let defaultPoints: Double

  /// The zoomed size, or nil for "graphcode's default".
  ///
  /// Kept as an optional rather than collapsed into a plain number equal to
  /// `defaultPoints`: nil is what survives a config change. An un-zoomed terminal stores
  /// nothing, so raising `font-size` in `~/.config/ghostty/config` moves it, where a
  /// literal 11.7 on disk would hold it there forever.
  private(set) var points: Double?

  /// - Parameter configuredPoints: Ghostty's own `font-size`, *not* already scaled — the
  ///   scaling is this type's business, and doing it at the call site is how the stored
  ///   value and the rendered one drift apart.
  init(configuredPoints: Double, points: Double? = nil) {
    defaultPoints = Self.clamped(configuredPoints * Self.defaultScale)
    self.points = points.flatMap { Self.settled($0, against: defaultPoints) }
  }

  /// The size actually rendered, zoomed or not.
  var resolvedPoints: Double { points ?? defaultPoints }

  /// Whether this is graphcode's own size rather than one the user chose.
  var isDefault: Bool { points == nil }

  /// What ⌘=, ⌘− and ⌘0 mean. Named for the intent rather than the key, since the mapping
  /// from keystroke to intent is `adjustment(forKey:modifiers:)`'s business.
  enum Adjustment: Equatable {
    case zoomIn
    case zoomOut
    /// Back to `defaultPoints` — and back to *being* unset, not merely equal to it.
    case reset
  }

  /// This zoom with one adjustment applied.
  ///
  /// Zooming steps from `resolvedPoints`, so the first ⌘− off an un-zoomed terminal moves
  /// one point down from the default rather than from some remembered number.
  func adjusted(_ adjustment: Adjustment) -> Self {
    switch adjustment {
    case .zoomIn: return withPoints(resolvedPoints + Self.step)
    case .zoomOut: return withPoints(resolvedPoints - Self.step)
    case .reset: return withPoints(nil)
    }
  }

  private func withPoints(_ requested: Double?) -> Self {
    var updated = self
    updated.points = requested.flatMap { Self.settled($0, against: defaultPoints) }
    return updated
  }

  /// A requested size clamped into range, or nil if it is the default — so zooming out and
  /// back in leaves the terminal in exactly the state ⌘0 would.
  private static func settled(_ requested: Double, against defaultPoints: Double) -> Double? {
    let clamped = Self.clamped(requested)
    return abs(clamped - defaultPoints) < tolerance ? nil : clamped
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, minimumPoints), maximumPoints)
  }

  // MARK: - Talking to libghostty

  /// The binding action to hand `ghostty_surface_binding_action` for a live surface.
  ///
  /// Always an absolute `set_font_size`, never libghostty's `reset_font_size`, because the
  /// two no longer agree on what "default" means: `reset_font_size` restores Ghostty's own
  /// `font-size`, and graphcode's default is `defaultScale` of it. Absolute rather than a
  /// delta for a second reason too — surfaces are created at different moments, and one
  /// that missed a step would stay a point off forever.
  /// Two decimals rather than the `Double`'s own description, which for a scaled default is
  /// `11.700000000000001` — parsed identically by Ghostty and unreadable in its logs.
  var bindingAction: String { String(format: "set_font_size:%.2f", resolvedPoints) }

  /// What a *new* surface's `ghostty_surface_config_s.font_size` should be.
  ///
  /// Never zero, which is libghostty's "inherit the configured size" sentinel: inheriting
  /// would come up at Ghostty's 13 and then be corrected to 11.7 on the next keystroke, so
  /// every terminal would be born a size it isn't supposed to be.
  var surfaceConfigFontSize: Float { Float(resolvedPoints) }

  /// What to persist: zero for "not zoomed", the same value `UserDefaults` hands back for
  /// a key that was never written — so a first launch and a deliberate ⌘0 read identically,
  /// and both stay free to follow a later `font-size` change.
  var storedPoints: Double { points ?? 0 }

  // MARK: - Keystrokes

  /// Which adjustment a keystroke asks for, or nil if it isn't one — in which case the
  /// event belongs to the terminal and must be forwarded untouched.
  ///
  /// The same keys Ghostty binds by default (`Config.zig`): ⌘= and ⌘+ in, ⌘− out, ⌘0
  /// reset. `+` is matched as well as `=` because on a German layout the plus is its own
  /// key, and because ⇧⌘= arrives here as `+` on any layout.
  ///
  /// Control and option are rejected rather than ignored: ⌃⌘− is not this shortcut, and a
  /// terminal that swallowed it would be eating a keystroke the shell wanted.
  static func adjustment(
    forKey characters: String?, modifiers: NSEvent.ModifierFlags
  ) -> Adjustment? {
    let flags = modifiers.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), flags.isDisjoint(with: [.control, .option]) else {
      return nil
    }
    switch characters {
    case "=", "+": return .zoomIn
    case "-": return .zoomOut
    case "0": return .reset
    default: return nil
    }
  }
}
