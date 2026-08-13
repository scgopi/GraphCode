import Foundation

/// Whether a node's transcript has been written to since the last time it was read.
///
/// This exists because of what it replaced. `refreshSummary` used to ask only sessions
/// that `refreshPresence` had just found **busy** — the guard `refreshActivity` uses, and
/// the wrong one here. A turn's last beats are written and *then* the session goes idle,
/// so the closing narration always landed after the final busy poll and was never read:
/// the terminal said the turn was over while the rail sat on a beat from three minutes
/// earlier. Activity can be guarded that way because a quiet session genuinely has no
/// current tool call; a summary is the account of what happened, and the end of a turn is
/// the most important part of it.
///
/// So every unresolved node is asked now, busy or not, and this is what keeps that cheap:
/// one `stat` per node per poll, and the tail read only when the file has actually moved.
/// A quiet loop — the common case, and the one the old guard was protecting against —
/// costs a stat and nothing else.
///
/// Modification *dates* rather than a timestamp of our own: comparing against "when we
/// last read" needs a tolerance, and any tolerance is a window in which a final beat is
/// missed, which is the bug this is fixing. A date that has not changed means bytes that
/// have not changed.
actor TranscriptFreshness {
  static let shared = TranscriptFreshness()

  private var seen: [UUID: Date] = [:]

  /// True when `url` has been modified since this node last read it — and records the new
  /// date, so a caller that asks twice without a write in between gets `false` the second
  /// time.
  ///
  /// An unreadable date is `true`: failing towards reading keeps a summary correct at the
  /// cost of one tail read, where failing the other way would freeze the rail silently.
  /// `FileManager` rather than `URL.resourceValues`, which caches per `URL` instance and
  /// would hand back the date from the first call forever — a rail frozen by an
  /// optimisation, which is precisely the failure this type exists to end. Caught by its
  /// own test.
  func hasChanged(_ url: URL, forNode nodeID: UUID) -> Bool {
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
      as? Date
    guard let modified else { return true }
    guard seen[nodeID] != modified else { return false }
    seen[nodeID] = modified
    return true
  }

  /// Forgets a node, so a deleted loop doesn't hold a date forever.
  func forget(_ nodeID: UUID) {
    seen[nodeID] = nil
  }
}
