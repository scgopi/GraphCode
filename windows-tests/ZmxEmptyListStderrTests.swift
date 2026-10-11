import Foundation
import XCTest

@testable import GraphcodeKit

#if os(Windows)
  /// `zmx ls` with zero sessions writes "no sessions found" to stderr. A child whose
  /// stderr is `FileHandle.nullDevice` exits 1 on Windows for that write, which read as
  /// an unknown liveness and kept a loop's session from ever starting.
  final class ZmxEmptyListStderrTests: XCTestCase {
    private let cmd = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")

    func testChildWritingToStderrStillExitsZero() async throws {
      let result = await ZmxSessionLauncher.runCollectingOutput(
        cmd, ["/c", "echo no sessions found 1>&2"])

      XCTAssertEqual(result?.status, 0)
      XCTAssertEqual(result?.output, "")
    }

    func testEmptyListingWithStderrOutputIsAbsent() async throws {
      let listing = await ZmxSessionLauncher.runCollectingOutput(
        cmd, ["/c", "echo no sessions found 1>&2"])
      let result = try XCTUnwrap(listing)

      let liveness = ZmxSessionLauncher.sessionLiveness(
        lsStatus: result.status, lsOutput: result.output, sessionName: "graphcode-x")

      XCTAssertEqual(liveness, .absent)
    }
  }
#endif
