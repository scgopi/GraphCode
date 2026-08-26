import Foundation

/// Token and cost accounting for one loop's session — the data behind
/// docs/05-orchestrator.md#monitoring-surface's usage rollup and docs/08's "review
/// usage" principle.
///
/// **Every field is optional, and that is the honest part.** graphcode cannot see inside
/// a running `claude`: the session is a detached PTY under `zmx`, and nothing about that
/// arrangement exposes token counts. So this is a *reported* value — a backend's own
/// hooks write it into the session's `zmx` label store (the same channel presence uses),
/// and graphcode reads it back. Where no hook is installed, the answer is "not reported",
/// which the rollup shows as exactly that.
///
/// The alternative — estimating tokens from scrollback length, or displaying a
/// plausible-looking zero — would make a cost panel that lies, which is worse than one
/// that admits it doesn't know. A number a human might make a spending decision on has
/// to come from the thing that actually spent it.
public struct UsageSample: Codable, Equatable, Sendable {
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var costUSD: Double?
  /// When the backend last reported. `nil` means it never has.
  public var reportedAt: Date?

  public init(
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    costUSD: Double? = nil,
    reportedAt: Date? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.costUSD = costUSD
    self.reportedAt = reportedAt
  }

  /// Nothing has ever been reported for this loop.
  public var isEmpty: Bool {
    inputTokens == nil && outputTokens == nil && costUSD == nil
  }

  public var totalTokens: Int? {
    guard inputTokens != nil || outputTokens != nil else { return nil }
    return (inputTokens ?? 0) + (outputTokens ?? 0)
  }

  /// Parses a `zmx` usage label, in either of two shapes:
  ///
  /// - `key=value` pairs separated by spaces or commas — the original documented form.
  ///   It turns out a `zmx` label *value* can never actually hold one (`zmx set` takes
  ///   only `[A-Za-z0-9._-]` in a value, and `=` and `,` are both outside it), so
  ///   nothing writes it today; kept because parsing is cheap and a future writer with
  ///   a laxer transport shouldn't find half a parser.
  /// - `key.value` pairs joined by `_` — `input.559576_output.5397_cost.0.0042` — built
  ///   from exactly the bytes a label value may contain. This is what
  ///   `PresenceHooks.usageScript` writes, and the only form that survives `zmx set`;
  ///   the same charset wall `activityScript` hit is why the activity label is
  ///   percent-encoded. The value is everything after the *first* `.`, which is what
  ///   lets a cost keep its decimal point.
  ///
  /// Unknown keys are ignored rather than rejected, so a backend reporting more than
  /// graphcode understands doesn't lose the fields it does.
  ///
  /// Returns `nil` when nothing usable was found — an unparseable label must not become
  /// a confident zero.
  public static func parse(_ label: String, now: Date = Date()) -> UsageSample? {
    var sample = UsageSample(reportedAt: now)
    for pair in label.split(whereSeparator: { $0 == " " || $0 == "," }) {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      sample.assign(String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
    }
    if sample.isEmpty, !label.contains("=") {
      for pair in label.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "_") {
        let parts = pair.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { continue }
        sample.assign(String(parts[0]), String(parts[1]))
      }
    }
    return sample.isEmpty ? nil : sample
  }

  private mutating func assign(_ key: String, _ value: String) {
    switch key {
    case "inputTokens", "input": inputTokens = Int(value)
    case "outputTokens", "output": outputTokens = Int(value)
    case "costUSD", "cost": costUSD = Double(value)
    default: break
    }
  }

  public static func + (lhs: UsageSample, rhs: UsageSample) -> UsageSample {
    func add(_ a: Int?, _ b: Int?) -> Int? {
      guard a != nil || b != nil else { return nil }
      return (a ?? 0) + (b ?? 0)
    }
    func add(_ a: Double?, _ b: Double?) -> Double? {
      guard a != nil || b != nil else { return nil }
      return (a ?? 0) + (b ?? 0)
    }
    return UsageSample(
      inputTokens: add(lhs.inputTokens, rhs.inputTokens),
      outputTokens: add(lhs.outputTokens, rhs.outputTokens),
      costUSD: add(lhs.costUSD, rhs.costUSD),
      reportedAt: [lhs.reportedAt, rhs.reportedAt].compactMap { $0 }.max())
  }
}

extension LoopGraph {
  /// Per-graph rollup. Sums only what was actually reported — a graph where nothing
  /// reported rolls up to `nil`, not to zero.
  public var usage: UsageSample? {
    let samples = nodes.compactMap(\.usage)
    guard !samples.isEmpty else { return nil }
    return samples.dropFirst().reduce(samples[0], +)
  }

  /// How much of this graph is actually reporting usage. The rollup shows this next to
  /// the totals, because "$0.12 across 2 of 9 loops" and "$0.12 across 9 of 9" are very
  /// different claims.
  public var usageCoverage: (reporting: Int, total: Int) {
    (nodes.filter { $0.usage != nil }.count, nodes.count)
  }
}
