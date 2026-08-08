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
