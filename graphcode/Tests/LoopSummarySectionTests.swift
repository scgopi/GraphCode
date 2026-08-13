import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// What the summary section says in each of the four states the design names, and what
/// the card does with a beat.
///
/// Tested as a value rather than through the view, the way `LoopCardPresentationTests` is:
/// the judgements here are which state wins, where the "since you looked" line falls, and
/// whether the rail can appear empty. None of that needs pixels.
@Suite
struct LoopSummarySectionTests {
  private func beat(
    _ pass: Int, _ text: String, kind: BeatKind = .reading, at seconds: Int
  ) -> SummaryBeat {
    SummaryBeat(
      id: "p\(pass)-\(seconds)", at: Date(timeIntervalSince1970: Double(seconds)), pass: pass,
      kind: kind, text: text)
  }

  private func node(
    summary: LoopSummary?, state: LoopState = .running, presence: Presence? = .busy
  ) -> LoopNode {
    var node = LoopNode(title: "Usage", loopType: .goalBased, state: state)
    node.summary = summary
    if let presence {
      node.presence = PresenceReading(presence: presence, confidence: .reported)
    }
    return node
  }

  private let now = Date(timeIntervalSince1970: 1000)

  @Test
  func aSessionThatHasNotSpokenYetIsHonestAboutIt() {
    let presentation = LoopSummaryPresentation(node: node(summary: nil), now: now)

    #expect(presentation.mode == .starting)
    #expect(presentation.text == "Getting its bearings")
    #expect(presentation.evidence == "first beat lands in a moment")
  }

  @Test
  func theCurrentBeatIsTheOnlyThingAtFullSize() {
    let summary = LoopSummary(beats: [
      beat(7, "Traced totalTokens", at: 100),
      beat(7, "Found the double count", kind: .found, at: 200),
      beat(7, "Working out why cached tokens double-count", at: 940),
    ])

    let presentation = LoopSummaryPresentation(node: node(summary: summary), now: now)

    #expect(presentation.mode == .working)
    #expect(presentation.text == "Working out why cached tokens double-count")
    #expect(presentation.elapsed == "1m")
    // Chronological, oldest first — the rail reads in the same direction as the terminal
    // beside it, with the newest at the foot. The current beat is not repeated among them.
    #expect(presentation.receding.map(\.text) == ["Traced totalTokens", "Found the double count"])
    #expect(presentation.passLabel == "PASS 7")
  }

  /// The one rule the rail must not break: attention has exactly one source of truth, and
  /// it is not the summary.
  @Test
  func askingIsReadOffTheLoopsStateNotOffItsBeats() {
    let summary = LoopSummary(beats: [beat(2, "Reading the probe", at: 900)])

    let asking = LoopSummaryPresentation(
      node: node(summary: summary, state: .awaitingInput), now: now)
    #expect(asking.mode == .asking)
    #expect(asking.kind == .asking)
    // The beat is still the text — a question is just what the loop is doing now.
    #expect(asking.text == "Reading the probe")

    let working = LoopSummaryPresentation(node: node(summary: summary), now: now)
    #expect(working.mode == .working)
  }

  @Test
  func aResolvedLoopBecomesTheAccountOfItsRun() {
    var resolved = node(
      summary: LoopSummary(beats: [beat(7, "Cached reads no longer double-count", at: 900)]),
      state: .succeeded, presence: nil)
    resolved.metricHistory = (0..<7).map {
      MetricSample(
        value: 1400 - Double($0) * 50, recordedAt: Date(timeIntervalSince1970: Double($0)))
    }

    let presentation = LoopSummaryPresentation(node: resolved, now: now)

    #expect(presentation.mode == .resolved)
    #expect(presentation.kind == .done)
    #expect(presentation.text == "Cached reads no longer double-count")
    #expect(presentation.evidence?.hasPrefix("7 passes · 1.4k → 1.1k · ") == true)
  }

  @Test
  func theHairlineFallsWhereTheWindowLastLeftOff() {
    let summary = LoopSummary(beats: [
      beat(7, "oldest", at: 100), beat(7, "middle", at: 200), beat(7, "newest", at: 300),
    ])

    // Left when "oldest" was current: the two after it are unseen.
    let returning = LoopSummaryPresentation(
      node: node(summary: summary), now: now, seenBeatID: "p7-100")
    #expect(returning.unseen == 2)

    // Never left: no hairline at all rather than a section marked all-new.
    let first = LoopSummaryPresentation(node: node(summary: summary), now: now)
    #expect(first.unseen == 0)
  }

  /// The rail is draggable now that a beat is prose rather than a chip, and the stored
  /// width has to survive both a hand that overshoots and a defaults file with nothing in
  /// it — a rail 8 points wide is one nobody can get back.
  @Test
  func theRailsWidthIsBoundedWhateverItIsHanded() {
    #expect(LoopWorkspaceRail.clamped(40) == LoopWorkspaceRail.minimumWidth)
    #expect(LoopWorkspaceRail.clamped(4000) == LoopWorkspaceRail.maximumWidth)
    #expect(LoopWorkspaceRail.clamped(300) == 300)
    #expect(LoopWorkspaceRail.defaultWidth >= LoopWorkspaceRail.minimumWidth)
    #expect(LoopWorkspaceRail.defaultWidth <= LoopWorkspaceRail.maximumWidth)
  }

  /// A rail must never render an empty section — the argument that already keeps blank
  /// chrome out of the rail entirely.
  @Test
  func aLoopWithNothingToSayDrawsNoSection() {
    #expect(LoopSummaryPresentation.hasContent(node: node(summary: nil)) == false)
    #expect(LoopSummaryPresentation.hasContent(node: node(summary: LoopSummary())) == false)
    #expect(
      LoopSummaryPresentation.hasContent(
        node: node(summary: LoopSummary(beats: [beat(1, "Reading", at: 1)]))) == true)
  }

  // MARK: - The card

  @Test
  func theCardsLiveLinePrefersTheNewestBeat() {
    var node = node(summary: LoopSummary(beats: [beat(7, "Working out the double count", at: 1)]))
    node.activity = "reading UsageProbe.swift"
    node.metricHistory = [
      MetricSample(value: 1, recordedAt: Date()), MetricSample(value: 2, recordedAt: Date()),
    ]

    #expect(
      LoopCardPresentation(node: node).liveLine == "pass 2 · Working out the double count")
  }

  /// With the producer off there is no summary, and the card says exactly what it said
  /// before this feature existed.
  @Test
  func theCardFallsBackWhenNothingIsSummarising() {
    var node = node(summary: nil)
    node.activity = "reading UsageProbe.swift"
    #expect(LoopCardPresentation(node: node).liveLine == "reading UsageProbe.swift")

    var handed = LoopNode(
      title: "Usage", loopType: .goalBased,
      goal: GoalSpec(summary: "tokens per request under 1.2k", metricCommand: "./m.sh"),
      state: .running)
    handed.summary = nil
    #expect(LoopCardPresentation(node: handed).liveLine == "tokens per request under 1.2k")
  }
}
