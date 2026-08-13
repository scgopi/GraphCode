import GraphcodeKit
import SwiftUI

/// What the summary section says, worked out once and drawn twice — the rail's own header
/// block and the 26pt gutter it collapses to.
///
/// A value type rather than logic inside the view so the four states the design names —
/// starting, working, asking, resolved — are assertable without a window.
struct LoopSummaryPresentation: Equatable {
  enum Mode: Equatable {
    /// A session that has begun and not yet said anything. Honest about latency rather
    /// than empty.
    case starting
    case working
    /// The loop wants a human. Never derived from the summary itself — see `init`.
    case asking
    /// The account of a finished run.
    case resolved
  }

  let mode: Mode
  let kind: BeatKind
  let text: String
  let evidence: String?
  /// How long the current beat has been the current beat, mono, in the header row.
  let elapsed: String?
  /// The receding rows under the now block, newest first.
  let receding: [SummaryBeat]
  /// How many of `receding` landed since the human last looked — the `SINCE YOU LOOKED`
  /// hairline sits after this many rows.
  let unseen: Int
  let passes: [PassSummary]
  let earlierPasses: Int
  /// `PASS 7` plus where the metric got to, or nothing when there is no pass to name.
  let passLabel: String?
  let passDelta: String?

  /// Whether the section has anything to say at all. A rail must never render an empty
  /// section — see `LoopWorkspaceRail.hasContent`.
  static func hasContent(node: LoopNode) -> Bool {
    node.summary?.isEmpty == false
  }

  init(node: LoopNode, now: Date = Date(), seenBeatID: String? = nil) {
    let summary = node.summary ?? LoopSummary()
    let current = summary.current

    // **Attention is not read off the summary.** `asking` is a beat kind the readers never
    // produce: whether a loop wants a human is already answered by `state`/`presence`, and
    // the attention rollup, the card, the sidebar and the titlebar chip all key off that
    // one answer. A rail that decided for itself would be a second source of truth about
    // the only thing in the app that must have exactly one.
    if node.isResolved {
      mode = .resolved
      kind = .done
    } else if node.displayState.wantsHuman {
      mode = .asking
      kind = .asking
    } else if current == nil {
      mode = .starting
      kind = .thinking
    } else {
      mode = .working
      kind = current?.kind ?? .thinking
    }

    switch mode {
    case .starting:
      text = "Getting its bearings"
      evidence = "first beat lands in a moment"
    case .resolved:
      text = current?.text ?? node.goal?.summary ?? node.title
      evidence = Self.runAccount(node, now: now)
    case .asking:
      // The question itself if the session narrated one, and otherwise the plain fact.
      // Both are better than a beat about the tool call it stopped in the middle of.
      text = current?.text ?? "Waiting for you"
      evidence = current?.evidence
    case .working:
      text = current?.text ?? ""
      evidence = current?.evidence
    }

    elapsed = current.map { LoopCardPresentation.duration(now.timeIntervalSince($0.at)) }
    receding = summary.receding
    unseen = min(summary.unseenCount(since: seenBeatID), summary.receding.count)
    passes = summary.passes.reversed()
    earlierPasses = summary.earlierPasses
    let pass = current?.pass ?? summary.passes.last?.pass
    passLabel = pass.map { "PASS \($0)" }
    passDelta = summary.passes.last?.delta
  }

  /// `"7 passes · 1.4k → 1.1k · 2h 31m"` — what a finished run cost and what it moved.
  /// Every part is dropped when it isn't known rather than filled with a zero.
  static func runAccount(_ node: LoopNode, now: Date) -> String? {
    var parts: [String] = []
    let passes = node.metricHistory.count
    if passes > 0 { parts.append("\(passes) \(passes == 1 ? "pass" : "passes")") }
    if let first = node.metricHistory.first?.value, let last = node.metricHistory.last?.value,
      first != last
    {
      parts.append("\(LoopSummaryDeltas.number(first)) → \(LoopSummaryDeltas.number(last))")
    }
    parts.append(LoopCardPresentation.duration(now.timeIntervalSince(node.createdAt)))
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// The six kinds' colours, in the palette the app already owns.
///
/// Kept beside the presentation rather than on `BeatKind` itself: the kind is a fact about
/// a session and lives in `GraphcodeKit`, which draws nothing.
enum BeatKindAppearance {
  static func dot(_ kind: BeatKind) -> Color {
    switch kind {
    case .reading: return .white.opacity(0.45)
    case .editing: return Color(red: 0.098, green: 0.620, blue: 0.439)  // #199e70
    case .running: return Theme.paneFocusTint
    case .thinking: return Color(red: 0.565, green: 0.522, blue: 0.914)  // #9085e9
    case .found, .done: return Color(red: 0.188, green: 0.820, blue: 0.345)  // #30d158
    case .asking: return Color(red: 1.0, green: 0.624, blue: 0.039)  // #ff9f0a
    }
  }

  static func ink(_ kind: BeatKind) -> Color {
    switch kind {
    case .reading: return .white.opacity(0.6)
    case .editing: return Color(red: 0.435, green: 0.827, blue: 0.671).opacity(0.85)
    case .running: return Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.85)
    case .thinking: return Color(red: 0.706, green: 0.675, blue: 0.941).opacity(0.85)
    case .found, .done: return Color(red: 0.494, green: 0.894, blue: 0.608).opacity(0.9)
    case .asking: return Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.95)
    }
  }

  /// The now block's fill and border. `asking` wears the same amber every other attention
  /// surface in the app does; `resolved` the same green a succeeded card does.
  static func blockFill(_ mode: LoopSummaryPresentation.Mode, kind: BeatKind) -> Color {
    switch mode {
    case .asking: return dot(.asking).opacity(0.1)
    case .resolved: return dot(.done).opacity(0.08)
    case .starting: return .white.opacity(0.03)
    case .working: return Theme.paneFocusTint.opacity(0.09)
    }
  }

  static func blockBorder(_ mode: LoopSummaryPresentation.Mode, kind: BeatKind) -> Color {
    switch mode {
    case .asking: return dot(.asking).opacity(0.4)
    case .resolved: return dot(.done).opacity(0.26)
    case .starting: return .white.opacity(0.08)
    case .working: return Theme.paneFocusTint.opacity(0.26)
    }
  }
}
