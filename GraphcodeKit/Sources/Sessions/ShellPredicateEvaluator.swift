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

  private static func run(_ predicate: ShellPredicate) async -> (succeeded: Bool, output: String)? {
    let trimmed = predicate.command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let session = try PTYProcessSession(
        arguments: ["-l", "-c", "exec 2>/dev/null; eval \"$GRAPHCODE_PREDICATE\""],
        workingDirectory: predicate.workingDirectory,
        extraEnvironment: ["GRAPHCODE_PREDICATE": trimmed])
      return await session.waitCollectingOutput()
    } catch {
      return nil
    }
  }
}
