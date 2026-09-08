import Foundation
import GraphcodeKit
import MailroomKit
import Testing

@testable import graphcode

/// Whether a loop wears the Mailroom-watch envelope, and what its tooltip says
/// (`MailroomWatchPresentation`).
@Suite
struct MailroomWatchPresentationTests {
  private func node(watch: MailroomWatch?, state: LoopState = .running) -> LoopNode {
    LoopNode(title: "Triage", loopType: .goalBased, mailroomWatch: watch, state: state)
  }

  @Test
  func aLoopWithoutAWatchShowsNothing() {
    let plain = node(watch: nil)

    #expect(!MailroomWatchPresentation.showsGlyph(for: plain))
    #expect(MailroomWatchPresentation.tooltip(for: plain) == nil)
  }

  @Test
  func aWatchOnEveryPostSaysSoWithoutATopic() {
    let hearingAll = node(watch: MailroomWatch())

    #expect(MailroomWatchPresentation.showsGlyph(for: hearingAll))
    #expect(MailroomWatchPresentation.tooltip(for: hearingAll) == "Watching the Mailroom")
  }

  @Test
  func aWatchOnOneTopicNamesIt() {
    let narrowed = node(watch: MailroomWatch(topic: "design"))

    #expect(MailroomWatchPresentation.showsGlyph(for: narrowed))
    #expect(
      MailroomWatchPresentation.tooltip(for: narrowed) == "Watching the Mailroom · topic design")
  }

  @Test(arguments: [LoopState.succeeded, .failed, .stalled, .stopped])
  func aResolvedLoopHidesItsWatch(state: LoopState) {
    // The watch survives on the node, but nothing can ring a loop that has finished.
    let finished = node(watch: MailroomWatch(topic: "design"), state: state)

    #expect(!MailroomWatchPresentation.showsGlyph(for: finished))
    #expect(MailroomWatchPresentation.tooltip(for: finished) == nil)
  }
}
