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

    /// The production hook's shape: a real child through `runCollectingOutput`, mapped by
    /// `sessionLiveness`, behind a real `GraphStore.resumeSession`.
    private func ensures(stub: String) async -> Int {
      let ensured = EnsureCount()
      let store = GraphStore(
        onEnsureSession: { _, _ in ensured.increment() },
        onSessionLiveness: { [cmd] _, _ in
          let result = await ZmxSessionLauncher.runCollectingOutput(cmd, ["/c", stub])
          return ZmxSessionLauncher.sessionLiveness(
            lsStatus: result?.status, lsOutput: result?.output ?? "", sessionName: "graphcode-x")
        },
        panesLaunchAttendedSessions: false)
      await store.handle(
        .createNode(NodeDraft(title: "Docs", loopType: .turnBased, firstInstruction: "Write it")))
      let id = await store.graph.nodes[0].id
      let before = ensured.count
      await store.handle(.resumeSession(id))
      return ensured.count - before
    }

    func testResumeStartsTheSessionWhenAnEmptyListWritesToStderr() async {
      let count = await ensures(stub: "echo no sessions found 1>&2")
      XCTAssertEqual(count, 1)
    }

    func testResumeHoldsWhenTheListingGenuinelyFails() async {
      let count = await ensures(stub: "echo no sessions found 1>&2 & exit /b 1")
      XCTAssertEqual(count, 0)
    }

    /// stdout and stderr both on `FileHandle.nullDevice` is the second shape of the same
    /// bug (`cmd /c "echo x"` exits 1); `DiscardedStream` must not have it.
    private func exitStatus(discarding make: () -> Any) throws -> Int32 {
      let process = Process()
      process.executableURL = cmd
      process.arguments = ["/c", "echo x"]
      process.standardOutput = make()
      process.standardError = make()
      process.standardInput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus
    }

    func testNullDeviceOnBothOutputStreamsIsTheBrokenShape() throws {
      XCTAssertEqual(try exitStatus { FileHandle.nullDevice }, 1)
    }

    func testDiscardedStreamOnBothOutputStreamsExitsZero() throws {
      XCTAssertEqual(try exitStatus { DiscardedStream.handle() }, 0)
    }
  }
  private final class EnsureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() {
      lock.lock()
      stored += 1
      lock.unlock()
    }
    var count: Int {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
  }
#endif
