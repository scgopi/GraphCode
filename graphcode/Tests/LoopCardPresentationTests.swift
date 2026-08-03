import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// What a loop card says (`LoopCardPresentation`).
///
/// Tested as a value rather than through the view: the judgement on a card is which
/// field becomes the live line, whether a metric moved the right way, and whether there
/// is anything to draw a bar for at all. None of that needs pixels, and a card that
/// reports a trend backwards is a card that stops a loop that was working.
@Suite
struct LoopCardPresentationTests {
  private func goalNode(
    metrics: [Double], direction: MetricDirection, state: LoopState = .running
  ) -> LoopNode {
    LoopNode(
      title: "Trim tokens",
      loopType: .goalBased,
      goal: GoalSpec(
        summary: "tokens per request under 1.2", metricCommand: "./metric.sh",
        metricDirection: direction),
      metricHistory: metrics.enumerated().map {
        MetricSample(value: $1, recordedAt: Date(timeIntervalSince1970: Double($0) * 60))
      },
      state: state)
  }

  private func progress(_ node: LoopNode) -> LoopCardPresentation.Progress? {
    guard case .progress(let progress) = LoopCardPresentation(node: node).detail else {
      return nil
    }
    return progress
  }

  @Test
  func aFallingMetricIsProgressWhenLowerIsBetter() {
    let bar = progress(goalNode(metrics: [1.42, 1.10], direction: .minimize))

    #expect(bar?.readings == "1.42 → 1.10")
    // Words rather than a sign: `+23%` beside a falling number reads as "went up".
    #expect(bar?.change == "23% better")
    #expect((bar?.fraction ?? 0) > 0)
  }

  @Test
  func theSameFallIsARegressionWhenHigherIsBetter() {
    // The whole reason `metricDirection` is declared rather than guessed: 1.42 → 1.10 is
    // a win for a failure count and a loss for a score.
    let bar = progress(goalNode(metrics: [1.42, 1.10], direction: .maximize))

    #expect(bar?.fraction == 0)
    #expect(bar?.change == "23% worse")
  }

  @Test
  func aRisingMetricFillsTheBarWhenHigherIsBetter() {
    let bar = progress(goalNode(metrics: [0.50, 1.00], direction: .maximize))

    #expect(bar?.fraction == 0.5)
    #expect(bar?.change == "50% better")
    // Both readings at one precision — `0.50 → 1` reads as two different measurements.
    #expect(bar?.readings == "0.50 → 1.00")
  }

  @Test
  func aMetricGoingTheWrongWayEmptiesTheBarRatherThanInvertingIt() {
    let bar = progress(goalNode(metrics: [1.00, 0.50], direction: .maximize))

    #expect(bar?.fraction == 0)
  }

  @Test
  func noReadingsMeansNoBarRatherThanZeroPercent() {
    // A bar at 0% is a claim about a metric. A loop that has never sampled one hasn't
    // made that claim, and drawing it as failing to improve would be the card inventing
    // a result.
    #expect(LoopCardPresentation(node: goalNode(metrics: [], direction: .maximize)).detail == .none)
  }

  @Test
  func oneReadingIsNotYetATrend() {
    #expect(
      LoopCardPresentation(node: goalNode(metrics: [0.71], direction: .maximize)).detail == .none)
  }

  @Test
  func aLoopWaitingOnAPersonOffersTheActionInsteadOfTheBar() {
    // Both of these have a full metric history. Neither shows it: there is no progress
    // to report while the loop is stopped on a human, only something to do.
    let asking = goalNode(metrics: [1.42, 1.10], direction: .minimize, state: .awaitingInput)
    let stuck = goalNode(metrics: [1.42, 1.10], direction: .minimize, state: .blocked)

    #expect(
      LoopCardPresentation(node: asking).detail
        == .action(.init(title: "Reply", shortcut: "⏎")))
    #expect(
      LoopCardPresentation(node: stuck).detail
        == .action(.init(title: "Inspect", shortcut: nil)))
  }

  @Test
  func everyKindOfLoopQuotesWhateverItWasHandedAsItsLiveLine() {
    let goal = LoopNode(
      title: "a", loopType: .goalBased, goal: GoalSpec(summary: "the suite is green"))
    let timed = LoopNode(
      title: "b", loopType: .timeBased, triggerPrompt: "/loop 1h\n  check the inbox")
    let turn = LoopNode(title: "c", loopType: .turnBased, checkDescription: "diff reads clean")

    #expect(LoopCardPresentation(node: goal).liveLine == "the suite is green")
    // Collapsed to one line — a trigger prompt is a paragraph often enough that drawing
    // it verbatim would show three words and a lot of indentation.
    #expect(LoopCardPresentation(node: timed).liveLine == "/loop 1h check the inbox")
    #expect(LoopCardPresentation(node: turn).liveLine == "diff reads clean")
  }

  @Test
  func aCompositeSaysHowBigItIsAndWhetherItIsLive() {
    let inner = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"),
      nodes: [LoopNode(title: "one"), LoopNode(title: "two")])
    let composite = LoopNode(
      title: "Nightly", loopType: .composite, subGraph: inner, pilotState: .armed)

    #expect(LoopCardPresentation(node: composite).liveLine == "2 loops · Armed")
  }

  @Test
  func aLoopWithNothingWrittenDownHasNoLiveLineRatherThanAnEmptyOne() {
    let blank = LoopNode(title: "blank", checkDescription: " ")
    #expect(LoopCardPresentation(node: LoopNode(title: "bare")).liveLine == nil)
    #expect(LoopCardPresentation(node: blank).liveLine == nil)
  }

  @Test
  func theMetaRowNamesTheKindAndOnlyMentionsABackendThatIsNotTheDefault() {
    let start = Date(timeIntervalSince1970: 0)
    let plain = LoopNode(title: "a", loopType: .goalBased, createdAt: start)
    let dressed = LoopNode(
      title: "b", loopType: .timeBased, backend: .codex,
      worktreeBinding: WorktreeRef(
        id: "w", repositoryPath: "/tmp/r", worktreePath: "/tmp/w", branch: "loop/trim"),
      createdAt: start)
    let now = start.addingTimeInterval(3600 * 2 + 60 * 14)

    #expect(LoopCardPresentation(node: plain, now: now).meta == ["Goal", "2h 14m"])
    #expect(
      LoopCardPresentation(node: dressed, now: now).meta
        == ["Timed", "loop/trim", dressed.backend.displayName, "2h 14m"])
  }

  @Test
  func agesReadCoarselyAndNeverRunBackwards() {
    #expect(LoopCardPresentation.duration(0) == "0s")
    #expect(LoopCardPresentation.duration(-90) == "0s")
    #expect(LoopCardPresentation.duration(45) == "45s")
    #expect(LoopCardPresentation.duration(60 * 12) == "12m")
    #expect(LoopCardPresentation.duration(3600) == "1h")
    #expect(LoopCardPresentation.duration(3600 * 2 + 60 * 14) == "2h 14m")
    #expect(LoopCardPresentation.duration(86400 * 3 + 3600 * 5) == "3d 5h")
  }

  @Test
  func wholeNumbersStayWhole() {
    // A failure count reads 41, not 41.00 — the metric is whatever the script printed.
    #expect(LoopCardPresentation.number(41) == "41")
    #expect(LoopCardPresentation.number(0.715) == "0.71")
  }

  @Test
  func theCardSaysTheSameWordTheStatePillDoes() {
    let timed = LoopNode(title: "a", loopType: .timeBased, state: .idle)
    let goal = LoopNode(title: "b", loopType: .goalBased, state: .idle)

    #expect(LoopCardPresentation(node: timed).word == "SCHEDULED")
    #expect(LoopCardPresentation(node: goal).word == "IDLE")
  }
}
