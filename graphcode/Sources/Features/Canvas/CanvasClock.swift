import Combine
import Foundation

/// One tick for every elapsed label in the window.
///
/// Ages on cards are the only thing on a canvas that changes without anything happening,
/// and the obvious spelling — a `TimelineView` inside each card — is the expensive one:
/// it re-evaluates every card body on every tick, and those bodies sit on the canvas's
/// gesture path. A single shared publisher means twenty cards cost one wakeup, and the
/// canvas re-renders on the same schedule it would have anyway.
///
/// Thirty seconds, with tolerance, because `LoopCardPresentation.duration` is coarser
/// than that everywhere except the first minute.
enum CanvasClock {
  static let tick = Timer.publish(every: 30, tolerance: 5, on: .main, in: .common).autoconnect()
}
