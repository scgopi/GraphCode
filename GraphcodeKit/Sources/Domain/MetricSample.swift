import Foundation

/// Which way a goal's metric should move for a pass to count as progress. Declared
/// rather than guessed: "41 → 22" is improvement for a failure count and regression for
/// a score, and a trend decision that guessed wrong would stop a loop that was working.
public enum MetricDirection: String, Codable, CaseIterable, Sendable {
  case minimize
  case maximize

  public var displayName: String {
    switch self {
    case .minimize: return "lower is better"
    case .maximize: return "higher is better"
    }
  }
}

/// One reading of a goal's metric command — see `GoalSpec.metricCommand`. Taken once per
/// cycle pass, at re-entry, where the `until` predicate already runs; never estimated,
/// and a run that failed or printed no number records nothing (the `UsageSample` rule:
/// an unparseable answer must not become a confident zero).
public struct MetricSample: Codable, Equatable, Sendable {
  public var value: Double
  public var recordedAt: Date

  public init(value: Double, recordedAt: Date = Date()) {
    self.value = value
    self.recordedAt = recordedAt
  }
}

/// Trend questions over a node's metric history — pure functions so the plateau rule is
/// testable without a store, a subprocess, or a clock.
public enum MetricTrend {
  /// The number a metric script reported: its last non-empty line of stdout, parsed as
  /// a `Double`. Anything else is "not measured" — a metric someone will make a
  /// keep-going decision on has to be a number the script actually printed.
  public static func value(fromScriptOutput output: String) -> Double? {
    let lastLine =
      output
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty }
    return lastLine.flatMap(Double.init)
  }

  /// Whether the last `passes` samples show no improvement over the best that came
  /// before them. Needs at least `passes + 1` samples — with fewer there is no "before"
  /// to have improved on, and a loop must not be stopped for plateauing before it has
  /// had that many chances.
  public static func plateaued(
    _ samples: [Double], direction: MetricDirection, passes: Int
  ) -> Bool {
    guard passes > 0, samples.count > passes else { return false }
    let recent = samples.suffix(passes)
    let baseline = samples.prefix(samples.count - passes)
    guard let best = baseline.best(direction) else { return false }
    return !recent.contains { $0.isImprovement(over: best, direction) }
  }
}

extension Sequence where Element == Double {
  fileprivate func best(_ direction: MetricDirection) -> Double? {
    switch direction {
    case .minimize: return self.min()
    case .maximize: return self.max()
    }
  }
}

extension Double {
  fileprivate func isImprovement(over best: Double, _ direction: MetricDirection) -> Bool {
    switch direction {
    case .minimize: return self < best
    case .maximize: return self > best
    }
  }
}
