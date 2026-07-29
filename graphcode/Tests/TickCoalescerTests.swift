import Testing

@testable import graphcode

/// The bound on how much libghostty's wakeup callback can pile onto the main thread.
///
/// The only two things that matter here are the two failure modes: a coalescer that lets
/// every wakeup through doesn't bound anything (the freeze this exists to stop), and one
/// that never lets go strands a surface with output nobody ticks for.
@Suite
struct TickCoalescerTests {
  @Test("Only the first of a burst of wakeups schedules a tick")
  func burstCollapsesToOne() {
    let coalescer = TickCoalescer()
    #expect(coalescer.claim())
    #expect(!coalescer.claim())
    #expect(!coalescer.claim())
  }

  @Test("Releasing lets the next wakeup schedule again")
  func releaseReopensTheSlot() {
    let coalescer = TickCoalescer()
    #expect(coalescer.claim())
    coalescer.release()
    #expect(coalescer.claim())
  }

  /// `GhosttyRuntime.wakeup` releases before running the tick, so a wakeup arriving
  /// mid-tick queues the next one rather than being dropped. Without that ordering the
  /// surface waits for an unrelated wakeup to move its output along.
  @Test("A wakeup arriving while a tick runs claims the next tick")
  func wakeupDuringTickIsNotDropped() {
    let coalescer = TickCoalescer()
    #expect(coalescer.claim())
    // What the dispatched block does, in order.
    coalescer.release()
    let arrivedMidTick = coalescer.claim()
    #expect(arrivedMidTick)
  }

  @Test("Releasing without a claim outstanding is harmless")
  func releaseWithoutClaim() {
    let coalescer = TickCoalescer()
    coalescer.release()
    #expect(coalescer.claim())
  }
}
