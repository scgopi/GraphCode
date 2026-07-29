import os

/// Keeps at most one `ghostty_app_tick` queued on the main thread at a time.
///
/// libghostty calls `wakeup_cb` from its IO thread every time a surface has work waiting,
/// which under a session streaming output is far more often than the main thread can
/// drain — and graphcode runs several such sessions at once, each with a SwiftUI canvas
/// competing for the same thread. Enqueuing a `DispatchQueue.main.async` per callback (as
/// Ghostty's own app does, with a comment noting it hasn't been coalesced) lets the main
/// queue grow faster than it empties: every one of those blocks has to run before the next
/// event, click, or frame does, and the window stops responding until the output stops.
///
/// Coalescing is safe because `ghostty_app_tick` drains *everything* pending rather than
/// one item — so N queued ticks do exactly the work of one, and dropping the surplus loses
/// nothing. What it must not do is drop a wakeup that arrives after the pending tick has
/// started, which is why `release()` is called before the tick rather than after.
///
/// Not an actor: `wakeup_cb` is a C callback with no async context to suspend in, and the
/// whole point is to answer "is one already queued?" without hopping threads.
final class TickCoalescer: Sendable {
  private let isScheduled = OSAllocatedUnfairLock(initialState: false)

  /// True when the caller now owns the pending tick and should schedule it; false when
  /// one is already queued and this wakeup can be dropped.
  func claim() -> Bool {
    isScheduled.withLock { scheduled in
      guard !scheduled else { return false }
      scheduled = true
      return true
    }
  }

  /// Gives the slot up, so the next wakeup schedules a tick again.
  func release() {
    isScheduled.withLock { $0 = false }
  }
}
