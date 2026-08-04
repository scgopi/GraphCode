import AppKit
import Dependencies
import Foundation

/// Owns every live terminal surface, keyed by the `SurfaceRef.id` it belongs to.
///
/// **Why the app owns these and not SwiftUI.** A `GhosttyTerminalNSView` used to be built
/// in `makeNSView` and released the moment SwiftUI unmounted the view, which made SwiftUI
/// view identity the lifetime of a real terminal. Switching loops in the sidebar replaces
/// `AppFeature.State.openLoop`, every pane's `.id(ref.id)` changes, and so every surface
/// in the workspace was destroyed and a fresh one built: `ghostty_surface_free` (which
/// **joins the renderer thread and the IO thread**, blocking the main thread until both
/// stop), then `ghostty_surface_new`, a `zmx attach` process spawn, and a full scrollback
/// replay — all on the main thread, all before the next frame. That is the freeze people
/// saw when clicking between loops.
///
/// Holding surfaces here inverts it: SwiftUI may build and tear down its views as often as
/// it likes, and `GhosttyTerminalView` merely borrows the surface for as long as it is on
/// screen. Owning the surface views here and handing built ones to the representable is
/// what makes switching between loops instant.
///
/// A retained surface that isn't on screen is not idle by accident: `GhosttyTerminalNSView`
/// tells libghostty it is occluded as soon as it loses its window, which drops its render
/// thread to `.utility` and stops it drawing. Retention costs memory, not frames — which
/// is what `SurfaceRetentionPolicy` bounds.
@MainActor
final class TerminalSurfaceStore {
  static let shared = TerminalSurfaceStore()

  private var surfaces: [UUID: GhosttyTerminalNSView] = [:]
  private var policy: SurfaceRetentionPolicy

  init(capacity: Int = SurfaceRetentionPolicy.defaultCapacity) {
    policy = SurfaceRetentionPolicy(capacity: capacity)
  }

  /// The surface for `id`, building it only if this is the first time it has been asked
  /// for — or the first time since it aged out.
  ///
  /// `build` is a closure rather than a set of parameters because constructing a surface
  /// means constructing its whole command line, which `GhosttyTerminalView` already knows
  /// how to do and this has no business knowing.
  func surface(for id: UUID, build: () -> GhosttyTerminalNSView) -> GhosttyTerminalNSView {
    let view: GhosttyTerminalNSView
    if let existing = surfaces[id] {
      view = existing
    } else {
      view = build()
      surfaces[id] = view
    }
    // Only an unmounted surface may be aged out; see `SurfaceRetentionPolicy.touch`.
    if let evicted = policy.touch(id, isEvictable: { surfaces[$0]?.superview == nil }) {
      release(evicted)
    }
    return view
  }

  /// Closes surfaces for good — the tab or pane they belonged to was closed, not merely
  /// scrolled away from. Their `zmx` sessions survive this, exactly as they survived the
  /// old teardown-on-every-switch behaviour; what ends is the attach.
  func retire(_ ids: [UUID]) {
    for id in ids {
      policy.forget(id)
      release(id)
    }
  }

  /// Whether a surface for `id` is currently alive. For tests and for callers deciding
  /// whether a rebuild is about to happen.
  func isRetained(_ id: UUID) -> Bool { surfaces[id] != nil }

  var retainedCount: Int { surfaces.count }

  /// Drops the store's reference, which is the last one for an unmounted surface and so
  /// runs its `deinit` — and with it `ghostty_surface_free`.
  ///
  /// The first-responder step is not decoration. An `NSWindow` holds a **strong**
  /// reference to its first responder, and `retire` is reachable for a surface that is
  /// both mounted and focused — closing the tab you are currently typing in is exactly
  /// that. Without handing the keyboard back, dropping the store's reference would free
  /// nothing: the terminal would keep its threads and its `zmx attach`, invisibly, for as
  /// long as the window lived. Eviction can't hit this (only unmounted surfaces are
  /// evictable) but explicit retirement can.
  private func release(_ id: UUID) {
    guard let view = surfaces.removeValue(forKey: id) else { return }
    if let window = view.window, window.firstResponder === view {
      window.makeFirstResponder(nil)
    }
    view.removeFromSuperview()
  }
}

/// Retiring surfaces from a reducer, which is where "this pane was closed" is actually
/// known.
///
/// A dependency rather than a direct call to the shared store for the reason every other
/// client here is one: a reducer test should not reach AppKit. Retirement is fire-and-
/// forget — there is no result to await and nothing downstream branches on it — so this is
/// a plain closure rather than an effect.
struct TerminalSurfaceClient: Sendable {
  var retire: @Sendable ([UUID]) -> Void
}

extension TerminalSurfaceClient: DependencyKey {
  static let liveValue = TerminalSurfaceClient(
    retire: { ids in
      guard !ids.isEmpty else { return }
      // Actions usually arrive on the main thread already; one that arrives from an
      // effect's own context must not tear a surface down from under the render thread.
      if Thread.isMainThread {
        MainActor.assumeIsolated { TerminalSurfaceStore.shared.retire(ids) }
      } else {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { TerminalSurfaceStore.shared.retire(ids) }
        }
      }
    })

  /// Tests exercise the retention rules against `SurfaceRetentionPolicy` directly; a
  /// reducer test asserting on tab bookkeeping has no surfaces to retire and should not
  /// spin up a `ghostty_app_t` to find that out.
  static let testValue = TerminalSurfaceClient(retire: { _ in })
}

extension DependencyValues {
  var terminalSurfaceClient: TerminalSurfaceClient {
    get { self[TerminalSurfaceClient.self] }
    set { self[TerminalSurfaceClient.self] = newValue }
  }
}
