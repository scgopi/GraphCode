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
  /// How many beats have landed since the human last looked, the current one included.
  let unseen: Int
  let passes: [PassSummary]
  let earlierPasses: Int
  /// Which pass the divider names, or nothing when there is no pass to name. A number
  /// rather than `PASS 7`: the word is the section's to draw, and the section is the layer
  /// that can be translated.
  let pass: Int?
  let passDelta: String?
  /// Whether the session is working this second. What separates `DOING NOW` from
  /// `LAST DID` — a beat is in the present tense only while something is producing beats,
  /// and a session parked at its prompt is describing the past.
  let isLive: Bool

  /// How many **receding rows** the hairline has to fall above.
  ///
  /// One fewer than `unseen`, because the current beat is one of the unseen beats and is
  /// not a row: it is the block under them. Drawing the hairline `unseen` rows from the
  /// end marked a row the human had demonstrably already read, every time.
  var unseenRows: Int { max(unseen - 1, 0) }

  /// Whether the section has anything to say at all. A rail must never render an empty
  /// section — see `LoopWorkspaceRail.hasContent`.
  static func hasContent(node: LoopNode) -> Bool {
    node.summary?.isEmpty == false
  }

  init(node: LoopNode, now: Date = Date(), seenBeatID: String? = nil) {
    let summary = node.summary ?? LoopSummary()
    let current = summary.current

    // **Attention is not read off the summary.** `asking` is a beat kind the readers never
    // produce: whether a loop wants a human is already answered by `state`, and the
    // attention rollup, the card, the sidebar and the titlebar chip all key off that one
    // answer. A rail that decided for itself would be a second source of truth about the
    // only thing in the app that must have exactly one.
    //
    // **`state`, not `displayState`** — the same split `LoopCardPresentation` makes, and
    // getting it wrong here was visible immediately. `displayState` turns a *running* loop
    // into `.awaitingInput` the moment its session's presence says so, and Claude Code
    // reports that presence for any `Notification`, including simply finishing a turn and
    // sitting at an empty prompt. So an amber block and an `Answer it` button appeared over
    // a loop that had asked nothing, under a beat that was not a question. The card has
    // always taken its *word* from `displayState` and its *affordance* from `state`; the
    // rail now does the same. A session quietly at its prompt is `waiting` below, not a
    // question.
    if node.isResolved {
      mode = .resolved
      kind = .done
    } else if node.state.wantsHuman {
      mode = .asking
      kind = .asking
    } else if current == nil {
      mode = .starting
      kind = .thinking
    } else {
      mode = .working
      kind = current?.kind ?? .thinking
    }

    // The rail's own words go through the catalog; a beat's never do. The app is shipped
    // in ten languages and the agent narrates in whichever one it is talking in, so a
    // translated frame around the session's own sentence is the only coherent answer.
    switch mode {
    case .starting:
      text = String(localized: "Getting its bearings")
      evidence = String(localized: "first beat lands in a moment")
    case .resolved:
      text = current?.text ?? node.goal?.summary ?? node.title
      evidence = Self.runAccount(node, now: now)
    case .asking:
      // The question itself if the session narrated one, and otherwise the plain fact.
      // Both are better than a beat about the tool call it stopped in the middle of.
      text = current?.text ?? String(localized: "Waiting for you")
      evidence = current?.evidence
    case .working:
      text = current?.text ?? ""
      evidence = current?.evidence
    }

    isLive = node.presence?.presence == .busy && !node.isResolved
    elapsed = current.map { LoopCardPresentation.duration(now.timeIntervalSince($0.at)) }
    receding = summary.receding
    // Counted against every beat, including the current one, and clamped to the rows the
    // hairline can actually sit between — the section draws it *above* a receding row, and
    // the current beat is not one of those. `LoopSummarySection` puts the leftover case —
    // only the now block is new — at the foot of the list, which is where it belongs.
    unseen = min(summary.unseenCount(since: seenBeatID), summary.beats.count)
    passes = summary.passes.reversed()
    earlierPasses = summary.earlierPasses
    // The beat's own pass, which `LoopSummary.merge` has already put on the store's
    // absolute numbering; `currentPass` for a section that is all rollups and no beats.
    pass = current?.pass ?? (summary.currentPass > 0 ? summary.currentPass : nil)
    passDelta = summary.passes.last?.delta
  }

  /// `"7 passes · 1.4k → 1.1k · 2h 31m"` — what a finished run cost and what it moved.
  /// Every part is dropped when it isn't known rather than filled with a zero.
  static func runAccount(_ node: LoopNode, now: Date) -> String? {
    var parts: [String] = []
    let passes = node.metricHistory.count
    if passes > 0 {
      parts.append(
        passes == 1
          ? String(localized: "1 pass") : String(localized: "\(passes) passes"))
    }
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
