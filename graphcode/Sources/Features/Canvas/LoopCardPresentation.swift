import Foundation
import GraphcodeKit

/// Everything a loop card says, resolved to plain values before any of it is drawn.
///
/// Split from `LoopCardView` because the card's content is where the judgement is —
/// which of four fields is the live line, whether a metric moved the right way, whether
/// there is a bar to draw at all — and none of that should need a rendered view to
/// check. The view is then only geometry and paint.
///
/// **Everything here comes off the node.** The design's richer live line ("pass 4 ·
/// editing UsageReport.swift") needs a session tail nothing reports yet; rather than
/// invent one, this falls back to what the loop was actually handed, which is honest and
/// still says more than the type name it replaces.
struct LoopCardPresentation: Equatable {
  /// The third row: a metric's trend, something to press, or nothing. Nothing is a real
  /// answer — a bar sitting at 0% is a claim about a metric, and a loop with no readings
  /// hasn't made one.
  enum Detail: Equatable {
    case none
    case progress(Progress)
    case action(Action)
  }

  struct Progress: Equatable {
    /// How full the bar is, 0...1. Never negative: a metric going the wrong way empties
    /// the bar rather than drawing a backwards one.
    let fraction: Double
    /// The readings behind it — `"1.42 → 1.10"`.
    let readings: String
    /// What they add up to — `"23% better"`, `"flat"`, `"8% worse"`.
    let change: String
  }

  struct Action: Equatable {
    let title: String
    let shortcut: String?
  }

  let word: String
  let liveLine: String?
  let detail: Detail
  /// The footer, already ordered: kind, branch, backend when it isn't the default, age.
  let meta: [String]

  init(node: LoopNode, now: Date = Date()) {
    word = node.state.displayWord(for: node.loopType)
    liveLine = Self.liveLine(node)
    detail = Self.detail(node, now: now)
    meta = Self.meta(node, now: now)
  }

  // MARK: - Live line

  private static func liveLine(_ node: LoopNode) -> String? {
    switch node.loopType {
    case .goalBased: collapsed(node.goal?.summary)
    case .timeBased: collapsed(node.triggerPrompt)
    case .turnBased: collapsed(node.checkDescription)
    case .proactive: compositeLine(node)
    }
  }

  private static func compositeLine(_ node: LoopNode) -> String {
    guard let subGraph = node.subGraph else { return node.pilotState.displayName }
    let count = subGraph.nodes.count
    return "\(count) \(count == 1 ? "loop" : "loops") · \(node.pilotState.displayName)"
  }

  /// One line, whatever was stored. A trigger prompt is a paragraph often enough that
  /// drawing it verbatim would leave the row showing its first three words and a lot of
  /// indentation.
  private static func collapsed(_ text: String?) -> String? {
    guard let text else { return nil }
    let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return joined.isEmpty ? nil : joined
  }

  // MARK: - Detail

  private static func detail(_ node: LoopNode, now: Date) -> Detail {
    if node.state.wantsHuman { return .action(action(for: node.state)) }
    if let metric = metricProgress(node) { return .progress(metric) }
    if let schedule = scheduleProgress(node, now: now) { return .progress(schedule) }
    return .none
  }

  private static func action(for state: LoopState) -> Action {
    // A question wants an answer typed into the session; a stuck wait wants a look at
    // what it is waiting on. Both open the loop, which is why the card takes one action.
    state == .awaitingInput
      ? Action(title: "Reply", shortcut: "⏎")
      : Action(title: "Inspect", shortcut: nil)
  }

  /// The trend, direction-aware: `metricDirection` decides which way is better, so a
  /// falling failure count and a rising score both fill the bar.
  ///
  /// Two samples minimum. One reading is not a trend, and drawing it as a flat bar would
  /// report a plateau the loop hasn't had the chance to be at yet.
  private static func metricProgress(_ node: LoopNode) -> Progress? {
    guard let direction = node.goal?.metricDirection, node.metricHistory.count >= 2,
      let first = node.metricHistory.first?.value, let last = node.metricHistory.last?.value
    else { return nil }

    let gain = direction == .maximize ? last - first : first - last
    // Relative to the larger of the two readings, so the bar means "how much of what was
    // there has moved" rather than being scaled by whatever units the script printed.
    let scale = Swift.max(abs(first), abs(last))
    let ratio = scale > 0 ? gain / scale : 0
    return Progress(
      fraction: Swift.min(Swift.max(ratio, 0), 1),
      readings: readings(first, last),
      change: changeLabel(ratio))
  }

  /// Words, not a signed percentage. `+23%` next to `1.42 → 1.10` reads as "went up",
  /// which is the opposite of what it means for a metric being minimised — the sign
  /// would be reporting the direction of the *number* while the bar reports the
  /// direction of the *work*.
  private static func changeLabel(_ ratio: Double) -> String {
    let percent = Int((abs(ratio) * 100).rounded())
    if percent == 0 { return "flat" }
    return "\(percent)% \(ratio > 0 ? "better" : "worse")"
  }

  /// How far a time-based loop is through its poll interval. Present for completeness
  /// and empty in practice: graphcode holds no interval of its own — a time-based loop's
  /// recurrence lives inside its session's prompt (see `LoopNode.triggerPrompt`) — so
  /// this only draws for a timed loop someone also gave a goal.
  private static func scheduleProgress(_ node: LoopNode, now: Date) -> Progress? {
    guard node.loopType == .timeBased, let goal = node.goal, goal.pollIntervalSeconds > 0,
      let last = node.metricHistory.last?.recordedAt
    else { return nil }

    let since = Swift.max(now.timeIntervalSince(last), 0)
    let due = Swift.max(goal.pollIntervalSeconds - since, 0)
    return Progress(
      fraction: Swift.min(since / goal.pollIntervalSeconds, 1),
      readings: "last run \(duration(since)) ago",
      change: due > 0 ? "next in \(duration(due))" : "due")
  }

  // MARK: - Meta

  private static func meta(_ node: LoopNode, now: Date) -> [String] {
    var parts = [node.loopType.displayName]
    if let branch = node.worktreeBinding?.branch { parts.append(branch) }
    // Only when it isn't the default — a badge on every card would be noise in the
    // overwhelmingly common single-backend graph. Unchanged rule, older than this card.
    if node.backend != .claudeCode { parts.append(node.backend.displayName) }
    parts.append(duration(Swift.max(now.timeIntervalSince(node.createdAt), 0)))
    return parts
  }

  // MARK: - Formatting

  /// A metric reading as the script would recognise it: whole numbers stay whole, so a
  /// failure count reads `41` rather than `41.00`.
  static func number(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e9
      ? String(Int(value))
      : String(format: "%.2f", value)
  }

  /// Both readings at one precision. Formatted apart, a pass that lands on a round
  /// number reads `0.50 → 1`, which looks like two different measurements rather than
  /// two samples of the same one.
  static func readings(_ first: Double, _ last: Double) -> String {
    let whole = first == first.rounded() && last == last.rounded()
    let text = { (value: Double) in whole ? number(value) : String(format: "%.2f", value) }
    return "\(text(first)) → \(text(last))"
  }

  /// Coarse on purpose — the card is redrawn from a 30-second tick, so a seconds figure
  /// on anything older than a minute would be stale as often as it was right.
  static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(Swift.max(seconds, 0))
    let (days, hours, minutes) = (total / 86400, total / 3600 % 24, total / 60 % 60)
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
  }
}
