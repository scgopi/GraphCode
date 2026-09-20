import Foundation
import Testing

@testable import GraphcodeKit

/// The dial log's bound, and the one property every writer to it owes.
///
/// `DialLog` trims by keeping the last `keptLines` lines once the file passes
/// `maxBytes` — a line-count trim standing in for a byte budget. It holds only while a
/// line stays under `maxBytes / keptLines`. A longer one breaks it *permanently*: the
/// trim keeps 5000 lines, 5000 long lines are still over the cap, so every later append
/// by every loop on that host re-reads and rewrites the whole file and never gets under.
///
/// A delivery-failure line shipped at 445 bytes against a 209-byte budget and did
/// exactly that — 2.2 MB of log that no trim could shrink. These lock the arithmetic so
/// raising `keptLines`, renaming a field, or adding a longer detail breaks here first.
@Suite
struct DialLogBoundTests {
  /// What one line may cost if `keptLines` of them must fit inside `maxBytes`.
  private var perLineBudget: Int { DialLog.maxBytes / DialLog.keptLines }

  @Test
  func aFailureLineFitsTheBudgetItsOwnTrimDependsOn() {
    let worstCase = RemoteGraphAccess.dialLineOverhead + RemoteGraphAccess.errorDetailBytes
    #expect(worstCase <= perLineBudget)
    #expect(DialLog.keptLines * worstCase <= DialLog.maxBytes)
    // Derived rather than chosen, so the two can never drift apart.
    #expect(
      RemoteGraphAccess.errorDetailBytes == perLineBudget - RemoteGraphAccess.dialLineOverhead)
  }

  @Test
  func theOverheadMatchesTheLineItBudgetsFor() {
    // The overhead constant is a measured string; if the fragment's fields change, the
    // budget must move with them rather than stay a stale number.
    let rendered = "2026-09-20T21:38:23Z delivery install failed "
    #expect(RemoteGraphAccess.dialLineOverhead == rendered.utf8.count)
    let fragment = DialLog.fragment(
      session: "delivery", dial: "install", event: "failed", detailVariable: "gc_di_err")
    #expect(fragment.contains("delivery install failed %s"))
  }

  @Test
  func whatIsLeftStillCarriesTheNameOfTheFault() {
    // A budget that fits the trim is worth nothing if it cannot hold a real diagnosis.
    let real =
      "NotADirectoryError: [Errno 20] Not a directory: "
      + "'/home/dev/blocker/nested/PROMPT.md'"
    #expect(real.utf8.count <= RemoteGraphAccess.errorDetailBytes)
    #expect("SyntaxError: invalid syntax".utf8.count <= RemoteGraphAccess.errorDetailBytes)
  }

  @Test
  func theTrimScratchFileIsPerProcess() {
    // A fixed `dials.log.tmp` is a race every loop on a host shares: two dials trimming
    // at once both redirect into one name and both `mv` it, publishing a half-written
    // file. Measured at 40 concurrent fragments, a 5000-line log came out with 34.
    let fragment = DialLog.fragment(session: "graphcode-x", dial: "ensure", event: "fresh")
    #expect(fragment.contains(".$$.tmp"))
    #expect(!fragment.contains("dials.log\".tmp"))
  }
}
