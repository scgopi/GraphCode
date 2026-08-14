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
  /// Under sixteen words — about three lines at the rail's 188pt content width. The
  /// budget was ten, and real beats kept losing their payload to the ellipsis
  /// ("…landed and the beta…"); anything still longer is two beats, or it is
  /// describing tools instead of intent.
  public let text: String
  /// `"UsageProbe.swift · 3 files read"` — where the beat came from, one line, mono.
  public let evidence: String?
  /// Whether the backend said the turn ended here — Claude Code's `stop_reason:
  /// end_turn`, Copilot's `assistant.turn_end`, Codex's `task_complete`.
  ///
  /// The rail used to take that from `presence`, and presence is a *reading* — a hook
  /// that may not have fired, a label that may be a poll behind. So a session that had
  /// delivered its answer and gone quiet still wore `DOING NOW` over the word `THINKING`,
  /// which is the one claim in the section that has to be true. The transcript says it
  /// outright, in the same record the beat itself came from.
  public let endsTurn: Bool

  public init(
    id: String, at: Date, pass: Int, kind: BeatKind, text: String, evidence: String? = nil,
    endsTurn: Bool = false
  ) {
    self.id = id
    self.at = at
    self.pass = pass
    self.kind = kind
    self.text = text
    self.evidence = evidence
    self.endsTurn = endsTurn
  }

  /// The same beat, with the backend's word that the turn stopped here.
  func endingTurn() -> SummaryBeat {
    SummaryBeat(
      id: id, at: at, pass: pass, kind: kind, text: text, evidence: evidence, endsTurn: true)
  }

  private enum CodingKeys: String, CodingKey {
    case id, at, pass, kind, text, evidence, endsTurn
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    at = try container.decode(Date.self, forKey: .at)
    pass = try container.decode(Int.self, forKey: .pass)
    kind = try container.decode(BeatKind.self, forKey: .kind)
    text = try container.decode(String.self, forKey: .text)
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
    // Absent in every beat banked before the backends were asked — and "we were never
    // told the turn ended" is exactly what `false` means.
    endsTurn = try container.decodeIfPresent(Bool.self, forKey: .endsTurn) ?? false
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
///
/// **Its pass numbers are window-relative and mean nothing on their own.** A transcript on
/// this machine reaches a hundred megabytes and the tail read is half of one, so a session
/// on its forty-first turn shows ten of them — measured, not supposed. The store turns
/// these into the numbers a person reads; see `LoopSummary.merge`, and `turns` for what it
/// counts with.
public struct SummaryReading: Equatable, Sendable {
  public var beats: [SummaryBeat]
  public var finishedPasses: [PassSummary]
  /// When each user turn the window saw happened, oldest first. The only thing in a
  /// reading that carries across polls: the store counts a pass when a turn arrives that
  /// is newer than the last one it counted, which is what makes a pass number survive the
  /// tail window sliding past the turn that opened it.
  public var turns: [Date]
  /// When each finished pass's last beat landed, by this reading's own pass number. What
  /// the metric's movement is attributed with — see `LoopSummary.merge`.
  public var passEndedAt: [Int: Date]
  /// The loop's metric series, unchanged. The store matches samples to passes by *when*
  /// they were taken, so nothing here has to know how the passes are numbered.
  public var metricSamples: [MetricSample]

  public init(
    beats: [SummaryBeat], finishedPasses: [PassSummary] = [], turns: [Date] = [],
    passEndedAt: [Int: Date] = [:], metricSamples: [MetricSample] = []
  ) {
    self.beats = beats
    self.finishedPasses = finishedPasses
    self.turns = turns
    self.passEndedAt = passEndedAt
    self.metricSamples = metricSamples
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
  /// Which pass the newest beats belong to, counted from the loop's own start rather than
  /// from the start of whatever the last tail read happened to reach.
  ///
  /// This is the number `PASS 7` prints, and it is here rather than on a beat because it
  /// is the one fact about a run that a reader cannot see: the transcript it reads half a
  /// megabyte of has a hundred megabytes behind it. The store counts a pass when
  /// `merge` is handed a user turn newer than `lastTurnAt`, so a pass that has scrolled
  /// out of the window is still counted, once.
  ///
  /// `0` means nothing has been merged yet. The first merge takes the window's own count,
  /// which is a floor: a loop graphcode started watching mid-run is on *at least* that
  /// many passes, and no reading can say more than that.
  public var currentPass: Int
  /// The newest user turn already counted into `currentPass`. What keeps a turn seen in
  /// six consecutive polls from counting six times.
  public var lastTurnAt: Date?

  public init(
    beats: [SummaryBeat] = [], passes: [PassSummary] = [], currentPass: Int = 0,
    lastTurnAt: Date? = nil
  ) {
    self.beats = beats
    self.passes = passes
    self.currentPass = currentPass
    self.lastTurnAt = lastTurnAt
  }

  /// Hand-written for the reason `LoopNode`'s is: a graph file that fails to decode is a
  /// graph the app reports as having no loops in it. Every field is optional on the way
  /// in, so a summary written by a build before this one — or after the next one — still
  /// loads.
  private enum CodingKeys: String, CodingKey {
    case beats, passes, currentPass, lastTurnAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    beats = try container.decodeIfPresent([SummaryBeat].self, forKey: .beats) ?? []
    passes = try container.decodeIfPresent([PassSummary].self, forKey: .passes) ?? []
    currentPass = try container.decodeIfPresent(Int.self, forKey: .currentPass) ?? 0
    lastTurnAt = try container.decodeIfPresent(Date.self, forKey: .lastTurnAt)
  }

  /// Finished passes with no line of their own, so `5 earlier passes` can be said without
  /// keeping five of anything.
  ///
  /// Derived rather than accumulated, now that `currentPass` is absolute: a loop adopted
  /// on its tenth pass has nine passes behind it whether or not graphcode ever saw them,
  /// and a counter that only knew about the rows it had dropped would have said none.
  public var earlierPasses: Int { max(0, currentPass - 1 - passes.count) }

  public var isEmpty: Bool { beats.isEmpty && passes.isEmpty }

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
  /// Four rules, and they are the whole of the bounding:
  ///
  /// 1. **The store numbers the passes.** A reading's are relative to a window that slides
  ///    as the transcript grows, so taking them at face value made `PASS 7` count
  ///    backwards as a session got long. Only a turn newer than `lastTurnAt` advances the
  ///    count, and everything in the reading is shifted onto that numbering.
  /// 2. **Beats of the newest pass only.** A beat belonging to an older pass has already
  ///    been rolled up, or is about to be; keeping it would make the section grow with the
  ///    run.
  /// 3. **A pass rolls up once.** A finished pass the store has never seen becomes one
  ///    `PassSummary` and the rest of its beats are dropped. A pass it already holds is
  ///    left alone — a reader whose tail window has moved on must not be able to rewrite
  ///    history it can no longer see.
  /// 4. **Everything past the cap becomes a number.** Oldest summaries go first, and
  ///    `earlierPasses` says how many are no longer named.
  public mutating func merge(_ reading: SummaryReading) {
    let relativeNewest = max(
      reading.beats.map(\.pass).max() ?? 0, reading.finishedPasses.map(\.pass).max() ?? 0)
    guard relativeNewest > 0 else { return }
    let newTurns = reading.turns.filter { $0 > (lastTurnAt ?? .distantPast) }
    currentPass = currentPass == 0 ? relativeNewest : currentPass + newTurns.count
    if let newest = newTurns.last { lastTurnAt = newest }
    let shift = currentPass - relativeNewest

    for summary in reading.finishedPasses.sorted(by: { $0.pass < $1.pass }) {
      let pass = summary.pass + shift
      guard pass > (passes.last?.pass ?? 0) else { continue }
      passes.append(
        PassSummary(
          pass: pass, text: summary.text, delta: Self.delta(of: summary.pass, in: reading))
      )
    }
    if passes.count > Self.maxPassSummaries {
      passes.removeFirst(passes.count - Self.maxPassSummaries)
    }
    // A reading with rollups but no beats leaves the ones on screen alone. No reader
    // produces one — a finished pass implies the beats it was summarised from — but the
    // alternative reading of "nothing" here is an empty rail, and the whole contract of
    // this method is that a reader cannot erase more than it can see.
    guard let newestPass = reading.beats.map(\.pass).max() else { return }
    beats =
      reading.beats
      .filter { $0.pass == newestPass }
      .suffix(Self.maxBeats)
      .map {
        SummaryBeat(
          id: $0.id, at: $0.at, pass: $0.pass + shift, kind: $0.kind, text: $0.text,
          evidence: $0.evidence)
      }
  }

  /// Where the metric got to over one pass, or nothing — which is most passes.
  ///
  /// **Matched by when the samples were taken, not by counting.** The first version keyed
  /// the series by position, on the assumption that sample *n* belongs to pass *n* — true
  /// of a `/loop` waking on a timer, and false the moment a human types twice in one pass
  /// or once between two. It printed the movement of a pass that was not the pass it was
  /// printed under, which is the one thing the section's only number must not do. A pass
  /// with no sample inside it, or a metric that did not move, says nothing.
  static func delta(of pass: Int, in reading: SummaryReading) -> String? {
    guard let ended = reading.passEndedAt[pass] else { return nil }
    let previous = reading.passEndedAt[pass - 1]
    let before = reading.metricSamples.last { $0.recordedAt <= (previous ?? .distantPast) }
    let after = reading.metricSamples.last { $0.recordedAt <= ended }
    guard let after, let before, before.value != after.value else { return nil }
    return "\(LoopSummaryDeltas.number(before.value)) → \(LoopSummaryDeltas.number(after.value))"
  }

  /// Same fold, without mutating — what a reader's output becomes when a node has no
  /// summary yet.
  public func merging(_ reading: SummaryReading) -> LoopSummary {
    var copy = self
    copy.merge(reading)
    return copy
  }
}
