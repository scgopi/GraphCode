import Foundation

/// Runs a `ShellPredicate` and reports whether it holds. The one place graphcode asks
/// the world a yes/no question: goal stop conditions
/// (docs/05-orchestrator.md#responsibilities item 4) and cyclic edges' `until` guards
/// both come through here.
///
/// Note what this is *not*: it never drives a loop's work and never touches a node's
/// session. The work runs in an ordinary attachable `zmx` session; this only observes,
/// from outside, whether the thing being waited for has arrived. That distinction is why
/// polling here doesn't reintroduce the headless fire-and-discard model `GraphStore`
/// deliberately removed — there is still a real terminal to attach to and steer the
/// whole time.
///
/// The command runs through a login shell so it resolves the same `PATH` a human would
/// get in a terminal, and is passed via the environment rather than interpolated into the
/// command string, so a predicate containing quotes or `;` can't break out of it.
public enum ShellPredicateEvaluator {
  /// The shape `GraphStore` injects. Returns `true` only when the command ran and exited
  /// 0 — a predicate that can't be run at all is "not yet", never "yes", since resolving
  /// a goal or stopping a cycle on a broken predicate would act on work nobody verified.
  public static let evaluate: @Sendable (ShellPredicate) async -> Bool = { predicate in
    await run(predicate)?.succeeded ?? false
  }

  /// The `evaluate` answer with its evidence still attached: pass/fail plus the tail of
  /// what the command printed, stderr included — a failing test suite says *why* on
  /// stderr, and a nudge built from a silenced stream would relay nothing. `nil` when
  /// the command couldn't be run at all, which callers must treat as "not yet", the
  /// same rule `evaluate` holds.
  public static let check: @Sendable (ShellPredicate) async -> PredicateOutcome? = { predicate in
    guard let result = await run(predicate, mergeStderr: true) else { return nil }
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return PredicateOutcome(passed: result.succeeded, outputTail: String(trimmed.suffix(600)))
  }

  /// Same mechanism, but the *output* is the answer rather than the exit status — a
  /// `.script` payload transform on an edge, where docs/08's "use scripts for
  /// deterministic work" means the script produces the hand-off content itself.
  public static let capture: @Sendable (ShellPredicate) async -> String? = { predicate in
    guard let result = await run(predicate), result.succeeded else { return nil }
    let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// What a human sees when they press **Test** on a done check: did it pass, and how
  /// long did it take.
  ///
  /// Only pass/fail, not the exit code itself: the session reports `terminationStatus ==
  /// 0` and nothing finer, and inventing a number for the failing case would be the
  /// dialog making up the one detail a person would act on. Same command, same shell,
  /// same working directory the daemon will use — a Test that ran it differently would
  /// be worse than no Test at all.
  public static let probe:
    @Sendable (ShellPredicate) async -> (passed: Bool, duration: TimeInterval)? = { predicate in
      let started = Date()
      guard let result = await run(predicate) else { return nil }
      return (result.succeeded, Date().timeIntervalSince(started))
    }

  /// A pipe, deliberately not a PTY. This used to run through `PTYProcessSession`, and
  /// that transport ate the answer: on macOS a PTY's unread buffer is not guaranteed to
  /// survive the child's exit, and under a background-QoS launchd daemon the reader
  /// reliably lost that race — every metric script that printed its number and exited
  /// logged "not measured", with `metricHistory` empty on every node this machine ever
  /// ran. (A post-exit drain of the master fd recovered nothing, which is how the
  /// discard was confirmed; the same code wins the race in a foreground test process,
  /// so no unit test caught it.) A pipe has none of this: the kernel keeps buffered
  /// pipe output readable after exit, and nothing here needs a terminal — the command
  /// is a predicate or metric script, not an interactive session. The pipe also ends
  /// the PTY's `^D\b\b` prelude garbling single-line output.
  private static func run(
    _ predicate: ShellPredicate, mergeStderr: Bool = false
  ) async -> (succeeded: Bool, output: String)? {
    let trimmed = predicate.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", "eval \"$GRAPHCODE_PREDICATE\""]
    if let workingDirectory = predicate.workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys where AgentEnvironment.isInheritedAgentIdentity(key) {
      environment.removeValue(forKey: key)
    }
    environment["GRAPHCODE_PREDICATE"] = trimmed
    process.environment = environment

    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = mergeStderr ? stdout as Any : FileHandle.nullDevice as Any
    process.standardInput = FileHandle.nullDevice

    // Reader and exit are joined by a group, not sequenced: reading after exit
    // deadlocks a child that filled the pipe, exiting after read is the general case.
    // The termination handler is set before `run` so no exit can slip between them.
    let group = DispatchGroup()
    let collected = CollectedOutput()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
      collected.data = stdout.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    group.enter()
    process.terminationHandler = { _ in group.leave() }

    do { try process.run() } catch {
      process.terminationHandler = nil
      group.leave()
      // Unblock the reader: with no child, only closing the write end delivers EOF.
      try? stdout.fileHandleForWriting.close()
      return nil
    }

    return await withCheckedContinuation { continuation in
      group.notify(queue: .global(qos: .utility)) {
        continuation.resume(
          returning: (
            succeeded: process.terminationStatus == 0,
            output: String(data: collected.data, encoding: .utf8) ?? ""
          ))
      }
    }
  }

  /// Reference box for the reader thread's result; the `DispatchGroup` orders the
  /// write before the read, it just needs somewhere mutable to live.
  private final class CollectedOutput: @unchecked Sendable {
    var data = Data()
  }
}
