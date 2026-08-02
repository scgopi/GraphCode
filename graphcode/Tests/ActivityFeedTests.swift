import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// The activity strip's derived feed (`ActivityFeed`), and the reported live line that
/// closes the other half of Phase 5's data gap.
///
/// What is being guarded is the claim the strip makes about itself: every event on it
/// happened, at the time it says, because something in the graph recorded it. A strip
/// that invented plausible timestamps would be worse than no strip — it would be a
/// history you could not check.
@Suite
struct ActivityFeedTests {
  private static let now = Date(timeIntervalSince1970: 100_000)

  private typealias Source = (graph: LoopGraph, path: String)

  private func source(_ nodes: [LoopNode], edges: [LoopEdge] = []) -> [Source] {
    [
      (
        LoopGraph(
          project: ProjectRef(path: "/tmp/p", name: "p"),
          nodes: IdentifiedArrayOf<LoopNode>(uniqueElements: nodes),
          edges: IdentifiedArrayOf<LoopEdge>(uniqueElements: edges)),
        "/tmp/p"
      )
    ]
  }

  private func event(_ minutesAgo: Double, state: LoopState = .running) -> ActivityEvent {
    ActivityEvent(
      id: "state-\(minutesAgo)",
      at: Self.now.addingTimeInterval(-minutesAgo * 60),
      nodeID: UUID(),
      projectPath: "/tmp/p",
      nodeTitle: "loop",
      kind: .state(state))
  }

  @Test
  func aMetricSampleIsAnEventDatedWhenItWasTaken() {
    // The one kind of event the graph already remembers precisely — a sample carries the
    // time it was recorded, so nothing has to be guessed or logged.
    let node = LoopNode(
      title: "Trim tokens",
      metricHistory: [
        MetricSample(value: 1.4, recordedAt: Self.now.addingTimeInterval(-600)),
        MetricSample(value: 1.1, recordedAt: Self.now.addingTimeInterval(-60)),
      ])

    let events = ActivityFeed.events(derivedFrom: source([node]), observed: [], now: Self.now)

    #expect(events.count == 2)
    #expect(events.first?.at == Self.now.addingTimeInterval(-60))
    #expect(events.first?.text == "Trim tokens · pass 1.10")
  }

  @Test
  func anUnfiredEdgeIsNotAnEvent() {
    // An edge that hasn't fired is a plan, not something that happened.
    let first = LoopNode(title: "first", createdAt: Self.now)
    let second = LoopNode(title: "second", createdAt: Self.now)
    let events = ActivityFeed.events(
      derivedFrom: source(
        [first, second], edges: [LoopEdge(from: first.id, to: second.id)]),
      observed: [], now: Self.now)

    #expect(events.isEmpty)
  }

  @Test
  func aFiredEdgeIsAHandoffNamingBothEnds() {
    let first = LoopNode(title: "explore", createdAt: Self.now.addingTimeInterval(-120))
    let second = LoopNode(title: "judge", createdAt: Self.now.addingTimeInterval(-120))
    let edge = LoopEdge(from: first.id, to: second.id, fireCount: 1)

    let events = ActivityFeed.events(
      derivedFrom: source([first, second], edges: [edge]), observed: [], now: Self.now)

    #expect(events.map(\.text) == ["explore → judge"])
  }

  @Test
  func theStripLooksBackOneWindowAndNoFurther() {
    // A strip captioned "last 30 min" showing something from this morning is a strip
    // nobody can date at a glance.
    let events = ActivityFeed.events(
      derivedFrom: [], observed: [event(5), event(29), event(31), event(600)], now: Self.now)

    #expect(events.count == 2)
  }

  @Test
  func nothingIsDatedInTheFuture() {
    // A clock that moved backwards, or a sample stamped by another machine. Either way
    // the strip must not claim something has already happened.
    let events = ActivityFeed.events(derivedFrom: [], observed: [event(-5)], now: Self.now)
    #expect(events.isEmpty)
  }

  @Test
  func newestFirst() {
    let events = ActivityFeed.events(
      derivedFrom: [], observed: [event(20), event(2), event(9)], now: Self.now)

    #expect(events.map(\.at) == events.map(\.at).sorted(by: >))
  }

  @Test
  func theFilterKeepsWhatYouWouldHaveWantedToNotice() {
    let observed = [
      event(1, state: .running), event(2, state: .awaitingInput), event(3, state: .failed),
      event(4, state: .succeeded),
    ]
    let filtered = ActivityFeed.events(
      derivedFrom: [], observed: observed, now: Self.now, attentionOnly: true)

    #expect(filtered.count == 2)
    #expect(filtered.allSatisfy { $0.isAttention })
  }

  @Test
  func theSameEventArrivingTwiceIsListedOnce() {
    let repeated = event(3)
    let events = ActivityFeed.events(
      derivedFrom: [], observed: [repeated, repeated], now: Self.now)

    #expect(events.count == 1)
  }

  @Test
  func onlyTransitionsAreRecordedAndOnlyForLoopsAlreadySeen() {
    // A project's first broadcast carries its whole graph. Recording that as one event
    // per node, all stamped now, would describe nothing that happened while anyone was
    // looking — which is the difference between a history and a listing.
    let node = LoopNode(title: "alpha", state: .idle)
    let before = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [node])
    var moved = node
    moved.state = .running
    let after = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [moved])

    var log: [ActivityEvent] = []
    AppFeature.recordActivity(
      previous: nil, next: before, path: "/tmp/p", at: Self.now, into: &log)
    #expect(log.isEmpty)

    AppFeature.recordActivity(
      previous: before, next: after, path: "/tmp/p", at: Self.now, into: &log)
    #expect(log.map(\.text) == ["alpha · running"])

    // Same state again is not a transition.
    AppFeature.recordActivity(
      previous: after, next: after, path: "/tmp/p", at: Self.now, into: &log)
    #expect(log.count == 1)
  }

  @Test
  func theObservedLogStaysBounded() {
    // It lives as long as the app does, so it has to have a ceiling.
    var log: [ActivityEvent] = []
    var previous = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"))
    let node = LoopNode(title: "alpha", state: .idle)
    previous.nodes.append(node)

    for index in 0..<(AppFeature.activityLogLimit + 50) {
      var next = previous
      next.nodes[id: node.id]?.state = index.isMultiple(of: 2) ? .running : .idle
      AppFeature.recordActivity(
        previous: previous, next: next, path: "/tmp/p",
        at: Self.now.addingTimeInterval(Double(index)), into: &log)
      previous = next
    }

    #expect(log.count == AppFeature.activityLogLimit)
  }

  @Test
  func aReportedActivityBecomesTheLiveLineWithItsPassCount() {
    // Phase 5's other half: when a hook reports what the session is doing, the card says
    // that instead of what the loop was handed.
    let node = LoopNode(
      title: "Trim tokens",
      loopType: .goalBased,
      goal: GoalSpec(summary: "tokens per request under 1.2"),
      activity: "editing UsageReport.swift",
      metricHistory: (0..<4).map { MetricSample(value: Double($0), recordedAt: Self.now) })

    #expect(
      LoopCardPresentation(node: node).liveLine == "pass 4 · editing UsageReport.swift")
  }

  @Test
  func withNothingReportedTheCardStillSaysWhatTheLoopWasHanded() {
    let node = LoopNode(
      title: "Trim tokens",
      loopType: .goalBased,
      goal: GoalSpec(summary: "tokens per request under 1.2"))

    #expect(LoopCardPresentation(node: node).liveLine == "tokens per request under 1.2")
  }

}
