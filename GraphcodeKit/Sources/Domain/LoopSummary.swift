import Foundation

/// What a beat is about, in six words the rail colours rather than prints twice.
///
/// The shape of a pass — a long read, a short edit, a run, a finding — is meant to be
/// legible from the dots alone, before a word is read. `asking` and `done` are never
/// produced by a reader: they are what the rail shows when the node's own presence says a
/// human is wanted and when the node has resolved, so attention keeps one source of truth
/// (`AttentionRollup`) rather than gaining a second one inside the summary.
public enum BeatKind: String, Codable, Sendable, CaseIterable {
  case reading
  case editing
  case running
  case thinking
  case found
  case asking
  case done

  /// The tool phrase every backend reader already speaks — `"editing Foo.swift"`,
  /// `"running make check"` — mapped to the kind it belongs to. Unrecognised phrases are
  /// `thinking` rather than dropped: a beat with no tool calls under it is a session
  /// working something out, which is exactly what the word says.
  public static func inferred(fromPhrase phrase: String) -> BeatKind {
    let verb = phrase.split(separator: " ").first.map(String.init) ?? ""
    switch verb {
    case "editing", "writing": return .editing
    case "reading", "searching", "looking": return .reading
    case "running", "delegating", "using", "planning": return .running
    default: return .thinking
    }
  }
}

/// One shift in what a loop is trying to do.
///
/// Not one per tool call and not one per tick: twenty greps in a row are one beat. What
/// makes a new one is the agent saying, in its own words, that it has moved on — the
/// narration every backend writes into its own transcript before the calls it is about to
/// make. That is why nothing here is generated: `text` is the agent's sentence, `evidence`
/// names the file or command the beat came from, and a beat that can cite neither is not
/// emitted.
public struct SummaryBeat: Codable, Equatable, Sendable, Identifiable {
  /// Stable across polls so the rail doesn't re-animate a beat it is already showing, and
  /// so `seenBeatID` can name one. Derived from the transcript position rather than
  /// random — the same beat read twice is the same beat.
  public let id: String
  public let at: Date
  /// Which pass this belongs to, counted from the session's own user turns. A loop's
  /// wake-up is a user turn whether a human typed it or `/loop` did.
  public let pass: Int
  public let kind: BeatKind
  /// Under ten words. The rail's content width is 188pt and a beat needing three lines is
  /// two beats, or it is describing tools instead of intent.
  public let text: String
  /// `"UsageProbe.swift · 3 files read"` — where the beat came from, one line, mono.
  public let evidence: String?

  public init(
    id: String, at: Date, pass: Int, kind: BeatKind, text: String, evidence: String? = nil
  ) {
    self.id = id
    self.at = at
    self.pass = pass
    self.kind = kind
    self.text = text
    self.evidence = evidence
  }
}

/// A finished pass, in one line. What the pass ended up doing, plus where the metric got
/// to — the only number the section carries.
public struct PassSummary: Codable, Equatable, Sendable, Identifiable {
  public let pass: Int
  public let text: String
  public let delta: String?

  public var id: Int { pass }

  public init(pass: Int, text: String, delta: String? = nil) {
    self.pass = pass
    self.text = text
    self.delta = delta
  }
}

/// What a reader took off one session this poll, before any of it is folded into the
/// node's own bounded store.
///
/// Deliberately separate from `LoopSummary`: a reader sees only as far back as the tail it
/// read, so it can report the current pass in full and the last pass or two in summary,
/// and it must not be able to erase what the store already knows about passes that have
/// scrolled out of that window.
public struct SummaryReading: Equatable, Sendable {
  public var beats: [SummaryBeat]
  public var finishedPasses: [PassSummary]

  public init(beats: [SummaryBeat], finishedPasses: [PassSummary] = []) {
    self.beats = beats
    self.finishedPasses = finishedPasses
  }

  public var isEmpty: Bool { beats.isEmpty && finishedPasses.isEmpty }
}

/// A loop's narration, bounded by construction: the current beat, the two before it, one
/// line per finished pass down to the last few, and a count for everything older.
///
/// A six-hour loop and a six-minute one are the same height, and the same number of bytes
/// in the graph file. Nothing accumulates — that is the difference between this and the
/// terminal it exists to save you reading.
public struct LoopSummary: Codable, Equatable, Sendable {
  /// Newest last.
  ///
  /// Three — the now block plus two receding rows — was the fixed-height design's answer,
  /// and it stopped being the right one when the section became scrollable: a rail you can
  /// scroll has nothing to scroll to at three. Twelve is what a person can page back
  /// through and still be a fixed cost per node (a beat is a short line and two dates).
  public static let maxBeats = 12
  /// How many finished passes keep a line of their own before they become a count.
  public static let maxPassSummaries = 6

  public var beats: [SummaryBeat]
  public var passes: [PassSummary]
  /// Passes older than the ones `passes` still names. Kept as a number so `5 earlier
  /// passes` can be said without keeping five of anything.
  public var earlierPasses: Int

  public init(
    beats: [SummaryBeat] = [], passes: [PassSummary] = [], earlierPasses: Int = 0
  ) {
    self.beats = beats
    self.passes = passes
    self.earlierPasses = earlierPasses
  }

  public var isEmpty: Bool { beats.isEmpty && passes.isEmpty && earlierPasses == 0 }

  /// The beat the rail shows at full size, and the card shows in one line.
  public var current: SummaryBeat? { beats.last }

  /// The beats behind the current one, **oldest first** — the rows above it.
  ///
  /// Chronological, not newest-first. The rail sits beside a terminal that reads top to
  /// bottom with the newest line at the foot of it, and a panel that ran the other way
  /// meant reading the same run in two directions on one screen.
  public var receding: [SummaryBeat] { Array(beats.dropLast()) }

  /// How many beats have landed since `seenBeatID` was the newest one.
  ///
  /// The watermark is **not** stored here, and that is deliberate: "since you looked" is a
  /// fact about a person at a window, not about the loop. Two windows showing the same
  /// loop have different answers, and the daemon has none at all. `LoopWorkspaceFeature`
  /// owns it; this only knows how to count against it.
  ///
  /// A watermark naming a beat that has since rolled out of the store counts as nothing
  /// unseen rather than everything — the alternative marks a whole section new every time
  /// a pass rolls up, which is when the marker means least.
  public func unseenCount(since seenBeatID: String?) -> Int {
    guard let seenBeatID else { return 0 }
    guard let index = beats.firstIndex(where: { $0.id == seenBeatID }) else { return 0 }
    return beats.count - 1 - index
  }

  /// Folds a reader's view of a session into the store.
  ///
  /// Three rules, and they are the whole of the bounding:
  ///
  /// 1. **Beats of the newest pass only.** A beat belonging to an older pass has already
  ///    been rolled up, or is about to be; keeping it would make the section grow with the
  ///    run.
  /// 2. **A pass rolls up once.** A finished pass the store has never seen becomes one
  ///    `PassSummary` and the rest of its beats are dropped. A pass it already holds is
  ///    left alone — a reader whose tail window has moved on must not be able to rewrite
  ///    history it can no longer see.
  /// 3. **Everything past the cap becomes a number.** Oldest summaries go first, and
  ///    `earlierPasses` counts what went.
  public mutating func merge(_ reading: SummaryReading) {
    for summary in reading.finishedPasses.sorted(by: { $0.pass < $1.pass }) {
      guard !passes.contains(where: { $0.pass == summary.pass }) else { continue }
      guard summary.pass > (passes.last?.pass ?? 0) || passes.isEmpty else { continue }
      passes.append(summary)
    }
    if passes.count > Self.maxPassSummaries {
      let dropped = passes.count - Self.maxPassSummaries
      passes.removeFirst(dropped)
      earlierPasses += dropped
    }
    let newestPass = reading.beats.map(\.pass).max()
    beats =
      Array(
        reading.beats
          .filter { $0.pass == newestPass }
          .suffix(Self.maxBeats))
  }

  /// Same fold, without mutating — what a reader's output becomes when a node has no
  /// summary yet.
  public func merging(_ reading: SummaryReading) -> LoopSummary {
    var copy = self
    copy.merge(reading)
    return copy
  }
}
