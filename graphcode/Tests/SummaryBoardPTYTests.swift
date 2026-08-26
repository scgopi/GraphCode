import Foundation
import Testing

@testable import GraphcodeKit

/// What the board composer does to the machine's file descriptors, which is the failure
/// this whole path has already had once.
///
/// `SummaryModelWriter` leaked a PTY per call before `ZmxSessionLauncher.loginShellInvocation`
/// went in: `Process` never searches `PATH`, so a bare `claude` threw at launch, and the
/// pair `openpty` had already allocated was never closed. `kern.tty.ptmx_max` is 511, so a
/// caller whose launch reliably fails exhausts the host outright — and `graphcoded` runs for
/// weeks, so "until the process exits" means "until the machine reboots".
///
/// `SummaryBoardComposer` opens a PTY on exactly the same primitive, once per finished pass
/// per loop. These measure the three ways out of `compose` — the process answers, the
/// process outlives the timeout, the process never launches — and assert the descriptors
/// come back each time.
@Suite(.serialized)
struct SummaryBoardPTYTests {

  /// How many descriptors this process currently holds.
  ///
  /// Counted off `/dev/fd`, which on Darwin lists the calling process's open descriptors.
  /// Coarse — it counts every file, socket and pipe the test host has open — but a leak of
  /// one PTY *pair* per iteration is 25 descriptors over 25 iterations, which no amount of
  /// unrelated noise hides.
  private func openDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
  }

  /// The same shape `SummaryBoardComposer.compose` uses, so the test exercises the
  /// arrangement rather than a simplification of it.
  private func runOnce(
    executable: String, arguments: [String], timeout: Duration
  ) async -> Bool {
    guard
      let session = try? PTYProcessSession(
        executable: executable, arguments: arguments, workingDirectory: nil)
    else { return false }
    let outcome = await withTaskGroup(of: (Bool, String)?.self) { group in
      group.addTask { await session.waitCollectingOutput() }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next().flatMap { $0 }
      group.cancelAll()
      return first
    }
    session.terminate()
    return outcome != nil
  }

  private static let iterations = 25
  /// One pair per iteration would be 50; anything under a handful is the test host's own
  /// churn, not a leak.
  private static let tolerance = 6

  @Test
  func aProcessThatAnswersGivesItsDescriptorsBack() async {
    // Warm up once: the first PTY in a process allocates machinery the rest reuse, and
    // counting that as a leak would make the threshold meaningless.
    _ = await runOnce(executable: "/bin/sh", arguments: ["-c", "echo hello"], timeout: .seconds(5))
    let before = openDescriptors()
    for _ in 0..<Self.iterations {
      _ = await runOnce(
        executable: "/bin/sh", arguments: ["-c", "echo hello"], timeout: .seconds(5))
    }
    let after = openDescriptors()
    #expect(after - before <= Self.tolerance, "\(before) → \(after) over \(Self.iterations) runs")
  }

  /// The path that matters most: a backend that hangs. The timeout fires, `terminate()`
  /// sends `SIGTERM`, and the descriptors have to come back — or one wedged `claude -p` per
  /// poll per loop walks the host to 511 and stops every PTY on the machine.
  @Test
  func aProcessKilledByTheTimeoutGivesItsDescriptorsBack() async {
    _ = await runOnce(
      executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: .milliseconds(80))
    let before = openDescriptors()
    for _ in 0..<Self.iterations {
      let answered = await runOnce(
        executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: .milliseconds(80))
      // And the timeout genuinely bounds the wait rather than being decoration: without
      // this the loop would take twelve minutes rather than two seconds.
      #expect(!answered)
    }
    let after = openDescriptors()
    #expect(after - before <= Self.tolerance, "\(before) → \(after) over \(Self.iterations) runs")
  }

  /// **The original bug, kept as a test.** A launch that throws has already allocated a
  /// pair; `PTYProcessSession`'s `catch` closes the slave and its `deinit` closes the
  /// master. `compose` reaches this through `try?`, so a leak here would be silent.
  @Test
  func aLaunchThatNeverHappensGivesItsDescriptorsBack() async {
    _ = await runOnce(
      executable: "/nonexistent/graphcode-not-a-real-binary", arguments: [],
      timeout: .seconds(5))
    let before = openDescriptors()
    for _ in 0..<Self.iterations {
      let answered = await runOnce(
        executable: "/nonexistent/graphcode-not-a-real-binary", arguments: [],
        timeout: .seconds(5))
      #expect(!answered)
    }
    let after = openDescriptors()
    #expect(after - before <= Self.tolerance, "\(before) → \(after) over \(Self.iterations) runs")
  }

  /// The composer never names a bare executable, whatever the backend's own spelling is.
  ///
  /// This is the guard that keeps the original failure from coming back by a different
  /// door: `Process` resolves `executableURL` as a path and never searches `PATH`, so
  /// `claude` alone throws — every call, silently, leaking as it goes. Going through the
  /// launcher's login shell is what makes the invocation resolvable at all.
  @Test
  func everyBackendIsLaunchedThroughALoginShellRatherThanABareName() {
    for backend in CLISessionBackendKind.allCases {
      let invocation = SummaryModelWriter.invocation(forBackend: backend, prompt: "x")
      let launch = ZmxSessionLauncher.loginShellInvocation(
        of: invocation[0], arguments: Array(invocation.dropFirst()))
      #expect(launch[0].hasPrefix("/"), "\(backend) would launch \(launch[0]) as a path")
      #expect(FileManager.default.isExecutableFile(atPath: launch[0]))
    }
  }
}
