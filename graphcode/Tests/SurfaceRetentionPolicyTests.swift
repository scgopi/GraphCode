import Foundation
import Testing

@testable import graphcode

/// How long a terminal surface outlives the view that showed it.
///
/// The failure modes this guards are asymmetric, and that asymmetry is the whole design:
/// retaining too little means `ghostty_surface_free` (two blocking thread joins) and a
/// full rebuild on every sidebar switch, which is the freeze; retaining a surface that is
/// still mounted means the store drops its only reference without freeing anything and
/// then builds a *second* terminal for a session that already has one, which is
/// unrecoverable. So over-retaining is allowed and duplicate surfaces are not.
@Suite
struct SurfaceRetentionPolicyTests {
  /// Nothing is ever mounted, so anything may be aged out.
  private let anythingEvictable: (UUID) -> Bool = { _ in true }

  @Test("A surface under capacity is kept")
  func underCapacityEvictsNothing() {
    var policy = SurfaceRetentionPolicy(capacity: 3)
    #expect(policy.touch(UUID(), isEvictable: anythingEvictable) == nil)
    #expect(policy.touch(UUID(), isEvictable: anythingEvictable) == nil)
    #expect(policy.touch(UUID(), isEvictable: anythingEvictable) == nil)
  }

  @Test("Going over capacity lets go of the least recently used")
  func evictsLeastRecentlyUsed() {
    var policy = SurfaceRetentionPolicy(capacity: 2)
    let oldest = UUID()
    let middle = UUID()
    _ = policy.touch(oldest, isEvictable: anythingEvictable)
    _ = policy.touch(middle, isEvictable: anythingEvictable)
    #expect(policy.touch(UUID(), isEvictable: anythingEvictable) == oldest)
    #expect(policy.order.contains(middle))
  }

  /// The point of retention: going back to a loop you were just in has to be free. Using
  /// a surface again moves it to the back of the queue, so alternating between two of
  /// them never evicts either.
  @Test("Re-using a surface makes something else the eviction candidate")
  func touchingRefreshesRecency() {
    var policy = SurfaceRetentionPolicy(capacity: 2)
    let first = UUID()
    let second = UUID()
    _ = policy.touch(first, isEvictable: anythingEvictable)
    _ = policy.touch(second, isEvictable: anythingEvictable)
    // Back to the first — now the *second* is the stale one.
    #expect(policy.touch(first, isEvictable: anythingEvictable) == nil)
    #expect(policy.touch(UUID(), isEvictable: anythingEvictable) == second)
  }

  /// A mounted surface is retained by the view showing it whatever this decides, so
  /// "evicting" one would drop the store's reference without freeing the terminal — and
  /// the next lookup would spawn a duplicate session. Being briefly over capacity is the
  /// cheaper mistake.
  @Test("A mounted surface is never the one let go of")
  func mountedSurfacesAreNotEvicted() {
    var policy = SurfaceRetentionPolicy(capacity: 2)
    let mounted = UUID()
    let unmounted = UUID()
    _ = policy.touch(mounted, isEvictable: { _ in true })
    _ = policy.touch(unmounted, isEvictable: { _ in true })
    let evicted = policy.touch(UUID(), isEvictable: { $0 != mounted })
    #expect(evicted == unmounted)
    #expect(policy.order.contains(mounted))
  }

  @Test("Nothing is evicted when every retained surface is still mounted")
  func allMountedEvictsNothing() {
    var policy = SurfaceRetentionPolicy(capacity: 1)
    let mounted = UUID()
    _ = policy.touch(mounted, isEvictable: { _ in true })
    #expect(policy.touch(UUID(), isEvictable: { _ in false }) == nil)
  }

  /// The surface being asked for right now is never a candidate, even at capacity 1 —
  /// evicting it would free the terminal the caller is about to show.
  @Test("The surface just asked for is never evicted")
  func theRequestedSurfaceSurvives() {
    var policy = SurfaceRetentionPolicy(capacity: 1)
    let first = UUID()
    let second = UUID()
    _ = policy.touch(first, isEvictable: anythingEvictable)
    #expect(policy.touch(second, isEvictable: anythingEvictable) == first)
    #expect(policy.order == [second])
  }

  @Test("A closed surface is forgotten rather than aged out")
  func forgetDropsImmediately() {
    var policy = SurfaceRetentionPolicy(capacity: 3)
    let closed = UUID()
    _ = policy.touch(closed, isEvictable: anythingEvictable)
    policy.forget(closed)
    #expect(!policy.order.contains(closed))
  }

  /// A capacity of zero would mean building and freeing a surface on every single
  /// lookup — the behaviour this type replaced.
  @Test("Capacity is at least one")
  func capacityFloor() {
    #expect(SurfaceRetentionPolicy(capacity: 0).capacity == 1)
    #expect(SurfaceRetentionPolicy(capacity: -5).capacity == 1)
  }
}
