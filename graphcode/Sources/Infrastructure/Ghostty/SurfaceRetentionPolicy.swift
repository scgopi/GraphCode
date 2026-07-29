import Foundation

/// Which terminal surfaces are worth keeping alive, and which one to let go of next.
///
/// Split out of `TerminalSurfaceStore` as a plain value so the bookkeeping can be tested
/// without a `ghostty_surface_t` behind it — the same split `TickCoalescer` got.
///
/// The whole reason surfaces are retained at all is that freeing one is *expensive and
/// synchronous*: `ghostty_surface_free` joins the surface's renderer thread and its IO
/// thread before returning, on whichever thread called it, which is always the main one.
/// Rebuilding costs a `ghostty_surface_new` plus a process spawn plus a scrollback
/// replay. Doing both on every sidebar switch is what made switching loops feel like the
/// app had hung. So a surface outlives the SwiftUI view that showed it, and this decides
/// how many may do so.
///
/// Least-recently-used, because the alternative — keeping everything — is not bounded by
/// anything: each live surface owns two threads and a scrollback, and a workspace can
/// have a hundred sessions in it.
struct SurfaceRetentionPolicy: Equatable {
  /// How many surfaces may stay alive at once. Sized for a working set of several loops
  /// rather than for all of them: switching between the handful you are actually going
  /// back and forth over is instant, and the rest pay the rebuild they used to pay every
  /// time.
  static let defaultCapacity = 12

  let capacity: Int

  /// Least recently used first, most recently used last.
  private(set) var order: [UUID] = []

  init(capacity: Int = defaultCapacity) {
    self.capacity = max(1, capacity)
  }

  /// Records that `id` was just used, and says which surface (if any) should now be let
  /// go of to stay within capacity.
  ///
  /// `isEvictable` is what stops this from evicting a surface that is still on screen.
  /// A surface currently mounted in a view is retained by that view whatever this type
  /// decides, so "evicting" one would drop the store's reference without actually freeing
  /// anything — and the next lookup would build a *second* surface for a session that
  /// already has one. Being briefly over capacity is bounded by the number of panes one
  /// loop can show at once, which is small; a duplicate session is not recoverable.
  mutating func touch(_ id: UUID, isEvictable: (UUID) -> Bool) -> UUID? {
    order.removeAll { $0 == id }
    order.append(id)
    guard order.count > capacity else { return nil }
    guard let victim = order.first(where: { $0 != id && isEvictable($0) }) else { return nil }
    order.removeAll { $0 == victim }
    return victim
  }

  /// Drops an id this policy no longer has any say over — the surface was closed
  /// outright rather than aged out.
  mutating func forget(_ id: UUID) {
    order.removeAll { $0 == id }
  }
}
