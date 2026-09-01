import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

/// The number behind the template editor's load-bearing line (PROMPT_TEMPLATES.md
/// § Follow vs snapshot): "3 scheduled loops use this — they'll pick up changes on
/// their next run."
///
/// The design calls that line load-bearing rather than decorative, so what it counts
/// has to be exactly right: loops that will actually change, not loops that merely
/// came from the template once.
@Suite
struct TemplateUsageTests {
  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/usage", name: "usage"),
      nodes: IdentifiedArray(uniqueElements: nodes))
  }

  @Test
  func followersAndSnapshotsAreCountedApart() {
    let id = UUID()
    let other = UUID()
    let usage = TemplateUsage.of(
      id,
      in: [
        graph([
          LoopNode(
            title: "Nightly", loopType: .timeBased, createdFromTemplateID: id,
            templateFollow: TemplateFollow(id: id, name: "Nightly")),
          LoopNode(
            title: "Weekly", loopType: .timeBased, createdFromTemplateID: id,
            templateFollow: TemplateFollow(id: id, name: "Nightly")),
          // Snapshotted at creation — an edit never reaches this one.
          LoopNode(title: "Green build", loopType: .goalBased, createdFromTemplateID: id),
          // Someone else's template entirely.
          LoopNode(
            title: "Other", loopType: .timeBased, createdFromTemplateID: other,
            templateFollow: TemplateFollow(id: other, name: "Other")),
          LoopNode(title: "Hand-made", loopType: .goalBased),
        ])
      ])

    #expect(usage.following == 2)
    #expect(usage.snapshots == 1)
    #expect(
      usage.followingLine
        == "2 scheduled loops use this — they'll pick up changes on their next run."
    )
    #expect(usage.snapshotLine == "1 loop started from it and keeps the brief it was created with.")
  }

  /// A follower inside a composite re-reads its template exactly like a top-level
  /// one, so the count has to see it.
  @Test
  func followersInsideACompositeAreCounted() {
    let id = UUID()
    let child = LoopNode(
      title: "Child", loopType: .timeBased,
      templateFollow: TemplateFollow(id: id, name: "Nightly"))
    let composite = LoopNode(
      title: "Group", loopType: .composite,
      subGraph: LoopGraph(
        project: ProjectRef(path: "sub", name: "sub"),
        nodes: IdentifiedArray(uniqueElements: [child])))

    #expect(TemplateUsage.of(id, in: [graph([composite])]).following == 1)
  }

  /// Counted across every project, because a home template is offered in all of them.
  @Test
  func usageSpansEveryProjectHandedIn() {
    let id = UUID()
    let follower = {
      LoopNode(
        title: "Nightly", loopType: .timeBased,
        templateFollow: TemplateFollow(id: id, name: "Nightly"))
    }
    let usage = TemplateUsage.of(id, in: [graph([follower()]), graph([follower()])])
    #expect(usage.following == 2)
  }

  @Test
  func nothingUsingItSaysNothing() {
    let usage = TemplateUsage.of(UUID(), in: [graph([LoopNode(title: "Alone")])])
    #expect(usage.isEmpty)
    #expect(usage.followingLine == nil)
    #expect(usage.snapshotLine == nil)
  }

  /// The singular reads as a sentence, not as "1 loops".
  @Test
  func theSingularIsWrittenOut() {
    #expect(
      TemplateUsage(following: 1).followingLine
        == "1 scheduled loop uses this — it'll pick up changes on its next run.")
  }
}
