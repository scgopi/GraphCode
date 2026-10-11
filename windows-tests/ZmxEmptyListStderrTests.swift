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

    /// Runs `cmd /c script` with the given sinks and waits at most `timeout` seconds;
    /// nil means it did not exit (a hang), and the child is terminated.
    private func exitStatus(
      script: String, stdout: Any, stderr: Any, timeout: TimeInterval = 10
    ) throws -> Int32? {
      let process = Process()
      process.executableURL = cmd
      process.arguments = ["/c", script]
      process.standardOutput = stdout
      process.standardError = stderr
      process.standardInput = FileHandle.nullDevice
      let exited = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in exited.signal() }
      try process.run()
      if exited.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if exited.wait(timeout: .now() + 5) == .timedOut {
          throw ReapError.couldNotReap
        }
        return nil
      }
      return process.terminationStatus
    }

    private enum ReapError: Error, CustomStringConvertible {
      case couldNotReap
      var description: String { "could not reap child after terminate()" }
    }

    func testInjectedEnvironmentReplacesInheritedKeyCaseInsensitively() {
      let merged = ZmxSessionLauncher.mergedEnvironment(
        ["zmx_dir": "wrong", "PATH": "p"], adding: ["ZMX_DIR": "expected"])
      XCTAssertEqual(merged["ZMX_DIR"], "expected")
      XCTAssertNil(merged["zmx_dir"])
      XCTAssertEqual(merged["PATH"], "p")
    }

    private static let flood =
      "for /l %i in (1,1,4000) do @echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

    /// Durable contract: a discarded stream never turns a child's output into a failure.
    func testDiscardedStreamOnBothOutputStreamsExitsZero() throws {
      let status = try exitStatus(
        script: "echo x", stdout: DiscardedStream.handle(), stderr: DiscardedStream.handle())
      XCTAssertEqual(status, 0)
    }

    func testDiscardedStreamAcceptsStderrOnlyWrites() throws {
      let status = try exitStatus(
        script: "echo no sessions found 1>&2", stdout: Pipe(), stderr: DiscardedStream.handle())
      XCTAssertEqual(status, 0)
    }

    /// The open-failure path: with `NUL` unopenable the sink is drained, so a child
    /// writing far more than a pipe buffer holds still exits instead of hanging.
    func testOpenFailureFallbackDoesNotHangAChattyChild() throws {
      var openAttempts = 0
      let failing: DiscardedStream.Opener = { _ in
        openAttempts += 1
        return nil
      }
      let status = try exitStatus(
        script: Self.flood,
        stdout: DiscardedStream.handle(opener: failing),
        stderr: DiscardedStream.handle(opener: failing))
      XCTAssertEqual(openAttempts, 2)
      XCTAssertEqual(status, 0, "nil means the child hung on an undrained fallback pipe")
    }

    func testOpenFailureFallbackDoesNotHangOnStderrFlood() throws {
      let failing: DiscardedStream.Opener = { _ in nil }
      let status = try exitStatus(
        script: Self.flood + " 1>&2", stdout: Pipe(),
        stderr: DiscardedStream.handle(opener: failing))
      XCTAssertEqual(status, 0, "nil means the child hung on an undrained fallback pipe")
    }

    /// Informational only: records whether this host's Foundation still maps
    /// `FileHandle.nullDevice` to the broken handle. It asserts nothing, so a Foundation
    /// fix cannot fail the build, and it is the reason `DiscardedStream` exists.
    func testNullDeviceDefectProbeIsInformational() throws {
      let status = try exitStatus(
        script: "echo x", stdout: FileHandle.nullDevice, stderr: FileHandle.nullDevice)
      print("INFO nullDevice both streams, cmd /c echo x -> exit \(String(describing: status))")
      let stdoutOnly = try exitStatus(
        script: "where cmd", stdout: FileHandle.nullDevice, stderr: DiscardedStream.handle())
      print("INFO nullDevice stdout only, where cmd -> exit \(String(describing: stdoutOnly))")
      let stderrOnly = try exitStatus(
        script: "echo x 1>&2", stdout: Pipe(), stderr: FileHandle.nullDevice)
      print(
        "INFO nullDevice stderr only, cmd /c echo x 1>&2 -> exit \(String(describing: stderrOnly))"
      )
    }

    // MARK: Real zmx.exe

    private func realZmx() -> URL? {
      let env = ProcessInfo.processInfo.environment
      var candidates: [String] = []
      if let exe = env["GRAPHCODE_ZMX_EXE"] { candidates.append(exe) }
      if let root = env["GRAPHCODE_ZMX_ROOT"] {
        candidates.append(root + "\\zig-out\\bin\\zmx.exe")
      }
      candidates.append(ZmxLocator.binaryURL.path)
      return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    }

    /// The reported defect, end to end: the real `zmx ls` against an empty `ZMX_DIR`
    /// writes "no sessions found" to stderr, and through `runCollectingOutput` must
    /// exit 0 and map to `.absent`. Skipped, visibly, when no `zmx.exe` exists.
    func testRealZmxEmptyListThroughRunCollectingOutput() async throws {
      guard let zmx = realZmx() else {
        if ProcessInfo.processInfo.environment["GRAPHCODE_REQUIRE_ZMX"] == "1" {
          XCTFail("GRAPHCODE_REQUIRE_ZMX=1 but no zmx.exe was found")
          return
        }
        throw XCTSkip(
          "no zmx.exe (set GRAPHCODE_ZMX_EXE or GRAPHCODE_ZMX_ROOT, or install beside graphcoded)")
      }
      // CI hands in a scratch directory owned by the current user (a workaround, see
      // coneilen/zmx#6); otherwise create one here.
      let scratch: URL
      if let provided = ProcessInfo.processInfo.environment["GRAPHCODE_ZMX_EMPTY_DIR"] {
        scratch = URL(fileURLWithPath: provided)
      } else {
        scratch = FileManager.default.temporaryDirectory
          .appendingPathComponent("zmx-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
      }
      let listing = await ZmxSessionLauncher.runCollectingOutput(
        zmx, ["ls"], extraEnvironment: ["ZMX_DIR": scratch.path])
      let result = try XCTUnwrap(listing, "zmx ls did not run")

      XCTAssertEqual(
        result.status, 0, "zmx ls output: \(result.output) (ZMX_DIR=\(scratch.path))")
      XCTAssertEqual(
        ZmxSessionLauncher.sessionLiveness(
          lsStatus: result.status, lsOutput: result.output, sessionName: "graphcode-x"),
        .absent)
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
