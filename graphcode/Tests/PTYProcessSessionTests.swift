import Foundation
import Testing

@testable import GraphcodeKit

/// The PTY primitive both the app and `graphcoded` spawn backends through. These tests
/// run real processes: the defect they pin — output written just before exit being
/// dropped — lives in the interplay of kernel PTY buffers and termination callbacks,
/// which no mock reproduces.
@Suite
struct PTYProcessSessionTests {
  /// A process that writes and immediately exits used to lose that output to the
  /// termination race: `terminationHandler` detached the reader and finished the stream
  /// before the readability callback ever saw the bytes. This is exactly the shape of a
  /// metric script (`echo 7; exit`), and it is why every metric read "not measured"
  /// while `metricHistory` stayed empty. Ten runs, because the old behavior was a race —
  /// a single pass could win by luck.
  @Test
  func fastExitingProcessKeepsItsFinalOutput() async throws {
    for _ in 0..<10 {
      let session = try PTYProcessSession(
        executable: "/bin/zsh", arguments: ["-c", "echo pre; echo 7"])
      let result = await session.waitCollectingOutput()

      #expect(result.succeeded)
      #expect(result.output.contains("7"))
    }
  }

  /// A launch that throws used to keep the slave half of the PTY it had already opened.
  /// `graphcoded` ran one such caller on every summary poll, so a machine left running
  /// bled `/dev/ttys*` entries until `kern.tty.ptmx_max` (511) was gone and nothing on the
  /// host — graphcode or otherwise — could open a terminal. Counted by path rather than by
  /// raw descriptor count so a sibling suite spawning its own processes cannot move the
  /// number a leak would move by exactly `attempts`.
  @Test
  func aLaunchThatFailsKeepsNoPTY() {
    func openTerminalDescriptors() -> Int {
      var count = 0
      var path = [CChar](repeating: 0, count: Int(PATH_MAX))
      for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
        guard let descriptor = Int32(name), fcntl(descriptor, F_GETPATH, &path) != -1 else {
          continue
        }
        if String(cString: path).hasPrefix("/dev/ttys") { count += 1 }
      }
      return count
    }

    let attempts = 20
    let before = openTerminalDescriptors()
    for _ in 0..<attempts {
      #expect(throws: (any Error).self) {
        _ = try PTYProcessSession(executable: "/no/such/binary", arguments: [])
      }
    }

    #expect(openTerminalDescriptors() - before < attempts)
  }

  /// The full metric pipeline short of `GraphStore`: the evaluator's real login-shell
  /// invocation, then the parser that reads its last non-empty line.
  @Test
  func aMetricScriptsNumberSurvivesTheCapturePath() async {
    let output = await ShellPredicateEvaluator.capture(
      ShellPredicate(command: "echo pre; echo 7", workingDirectory: nil))

    let value = output.flatMap(MetricTrend.value(fromScriptOutput:))
    #expect(value == 7.0)
  }

  /// The commonest real metric is a bare `echo 42` — one line, nothing else. Under the
  /// old PTY transport that only line arrived wearing the terminal's `^D\b\b` prelude,
  /// so `Double()` refused it; a pipe carries no terminal and no prelude.
  @Test
  func aSingleLineMetricParsesCleanly() async {
    let output = await ShellPredicateEvaluator.capture(
      ShellPredicate(command: "echo 42", workingDirectory: nil))

    #expect(output.flatMap(MetricTrend.value(fromScriptOutput:)) == 42.0)
  }

  /// A failing predicate must stay "no", and a chatty-but-failing metric must stay
  /// unmeasured — exit status gates the output, not the other way around.
  @Test
  func aFailingCommandsOutputIsNotMistakenForAnAnswer() async {
    let output = await ShellPredicateEvaluator.capture(
      ShellPredicate(command: "echo 9; exit 3", workingDirectory: nil))

    #expect(output == nil)
  }
}
