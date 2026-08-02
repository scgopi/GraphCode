import Foundation
import GraphcodeKit
import IdentifiedCollections
import Testing

@testable import graphcode

/// ⌘K's ranking (`JumpPalette`).
///
/// The ranking *is* the feature. A palette that puts a substring match above the loop
/// whose first three letters you typed is one you stop trusting after the second wrong
/// Return — at which point it costs more than the sidebar it was meant to replace.
@Suite
struct JumpPaletteTests {
  private typealias Source = (graph: LoopGraph, path: String)

  private func graphs(_ nodes: [LoopNode], project: String = "graphcode") -> [Source] {
    [
      (
        LoopGraph(
          project: ProjectRef(path: "/tmp/\(project)", name: project),
          nodes: IdentifiedArrayOf<LoopNode>(uniqueElements: nodes)),
        "/tmp/\(project)"
      )
    ]
  }

  @Test
  func aTitlePrefixOutranksASubstringWhichOutranksTheFolderName() {
    let prefix = LoopNode(title: "token trimmer")
    let substring = LoopNode(title: "trim the tokens")
    let byProject = LoopNode(title: "unrelated")

    let results = JumpPalette.results(
      query: "token",
      graphs: graphs([substring, byProject, prefix], project: "tokens"),
      attention: [])

    #expect(results.map(\.title) == ["token trimmer", "trim the tokens", "unrelated"])
  }

  @Test
  func aKindOrAStateIsAWayOfAskingForASetOfLoops() {
    let running = LoopNode(title: "alpha", state: .running)
    let timed = LoopNode(title: "beta", loopType: .timeBased)

    #expect(
      JumpPalette.results(query: "running", graphs: graphs([running, timed]), attention: [])
        .map(\.title) == ["alpha"])
    #expect(
      JumpPalette.results(query: "timed", graphs: graphs([running, timed]), attention: [])
        .map(\.title) == ["beta"])
  }

  @Test
  func aLoopWaitingOnAHumanBreaksTiesAndLeadsAnEmptyQuery() {
    let quiet = LoopNode(title: "aaa quiet match", state: .running)
    let asking = LoopNode(title: "zzz asking match", state: .awaitingInput)

    let empty = JumpPalette.results(
      query: "", graphs: graphs([quiet, asking]), attention: [asking.id])
    #expect(empty.map(\.title) == ["zzz asking match", "aaa quiet match"])
    #expect(empty.first?.needsHuman == true)

    // Within one rank: both are substring matches, and the one asking a question wins
    // despite sorting later alphabetically.
    let tied = JumpPalette.results(
      query: "match", graphs: graphs([quiet, asking]), attention: [asking.id])
    #expect(tied.first?.title == "zzz asking match")
  }

  @Test
  func typingALoopsNameBeatsAnythingElseWantingAHuman() {
    // The tiebreak is a tiebreak, not an override: if you typed the start of a name, you
    // want that loop, and a palette that answered with a different one because it was
    // waiting would be unusable for its main job.
    let named = LoopNode(title: "matcher", state: .running)
    let asking = LoopNode(title: "zzz match", state: .awaitingInput)

    let results = JumpPalette.results(
      query: "match", graphs: graphs([asking, named]), attention: [asking.id])

    #expect(results.map(\.title) == ["matcher", "zzz match"])
  }

  @Test
  func nothingTypedListsEveryLoopRatherThanNone() {
    // The palette opens before a keystroke, and an empty list would read as "no loops".
    let results = JumpPalette.results(
      query: "  ", graphs: graphs([LoopNode(title: "a"), LoopNode(title: "b")]), attention: [])
    #expect(results.count == 2)
  }

  @Test
  func aQueryMatchingNothingReturnsNothing() {
    #expect(
      JumpPalette.results(
        query: "kumquat", graphs: graphs([LoopNode(title: "a")]), attention: []
      ).isEmpty)
  }

  @Test
  func searchIsCaseInsensitiveAndIgnoresSurroundingSpace() {
    let node = LoopNode(title: "Token Trimmer")
    let results = JumpPalette.results(
      query: "  TOKEN ", graphs: graphs([node]), attention: [])

    #expect(results.map(\.title) == ["Token Trimmer"])
  }

  @Test
  func aResultCarriesTheFolderItBelongsToSoReturnHasSomewhereToGo() {
    let node = LoopNode(title: "alpha")
    let result = JumpPalette.results(query: "alpha", graphs: graphs([node]), attention: []).first

    #expect(result?.projectPath == "/tmp/graphcode")
    #expect(result?.nodeID == node.id)
    // The subtitle is the loop's own vocabulary, never a raw enum name.
    #expect(result?.subtitle == "Turn · IDLE · graphcode")
  }

  @Test
  func equalRanksFallBackToTheTitleSoTheOrderIsNeverArbitrary() {
    // `sorted` is not stable, so without a final tiebreak two equally-ranked loops could
    // swap places between keystrokes — the highlight would move under the fingers.
    let nodes = ["delta match", "alpha match", "charlie match"].map { LoopNode(title: $0) }
    let results = JumpPalette.results(query: "match", graphs: graphs(nodes), attention: [])

    #expect(results.map(\.title) == ["alpha match", "charlie match", "delta match"])
  }
}
