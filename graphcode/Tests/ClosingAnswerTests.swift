import Foundation
import Testing

@testable import GraphcodeKit

/// What reaches the composer, and what must not reach the graph file.
///
/// The first release handed it `LoopSummary` and nothing else — beats condensed to sixteen
/// words apiece — so a session whose answer was a table narrated it as "Four files exceed
/// their limits" and the composer correctly refused to draw a table it could not see.
/// Everything here is about carrying the answer itself, without persisting a slice of every
/// session into a file that has never held one.
@Suite
struct ClosingAnswerTests {

  private func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }

  /// **The bug the first release shipped with.** The composer was handed `LoopSummary` and
  /// nothing else — beats condensed to sixteen words each — so a session whose *answer* was
  /// a table of findings offered it "Four files exceed their limits" and it correctly
  /// refused to draw a table it could not see. Measured against the fast tier: the same run
  /// answered `NONE` on the beats and drew the table on the answer.
  @Test
  func theClosingAnswerIsCapturedWhenATurnEnds() {
    var builder = SummaryBeatBuilder()
    builder.noteUserTurn(at: Date(timeIntervalSince1970: 0))
    builder.noteNarration("Reading the lint output to see what it flags.", at: at(1))
    builder.noteTool("reading swiftlint.log", at: at(1))
    #expect(builder.closingAnswer() == nil, "nothing has ended a turn yet")

    let answer = """
      Four files are over their limits:

      | File | Actual | Limit |
      |---|---|---|
      | RemoteSessionResumeTests.swift | 438 | 400 |
      """
    builder.noteNarration(answer, at: at(2))
    builder.noteTurnEnd()

    #expect(builder.closingAnswer() == answer)
    // Threaded exactly as the backend readers thread it — the builder holds the answer and
    // the reading is handed it, so a reader that forgot to pass it carries nothing.
    let reading = SummaryBeatBuilder.reading(
      from: builder.beats(), turns: builder.userTurns(), closing: builder.closingAnswer())
    #expect(reading.closing == answer)
  }

  /// A page of the agent's own output, so it is capped before it is carried anywhere.
  @Test
  func theClosingAnswerIsCapped() {
    var builder = SummaryBeatBuilder()
    builder.noteNarration(String(repeating: "a", count: 9_000), at: at(1))
    builder.noteTurnEnd()
    #expect(builder.closingAnswer()?.count == SummaryBeatBuilder.maxClosing)
  }

  /// **It must not reach the graph file.** A beat is a sentence and has always been stored;
  /// this is raw session output, and a loop has to cost the same bytes on disk as it did
  /// before boards existed.
  @Test
  func theClosingAnswerIsNeverPersisted() throws {
    let reading = SummaryBeatBuilder.reading(
      from: [
        SummaryBeat(
          id: "b", at: at(1), pass: 1, kind: .found, text: "Found four", endsTurn: true)
      ],
      turns: [at(0)], closing: "a page of the agent's own output")

    var node = LoopNode(title: "A")
    node.summary = LoopSummary().merging(reading)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
    let encoded = try #require(String(data: JSONEncoder().encode(node), encoding: .utf8))
    #expect(!encoded.contains("a page of the agent's own output"))
    let summary = object["summary"] as? [String: Any]
    #expect(summary?["closing"] == nil)
  }

  /// **The failure a real transcript showed.** One slot for the closing answer is
  /// overwritten by every subsequent turn, so a human typing "thanks" replaced a mermaid
  /// diagram with "Anything else?" — and the board was then composed from the greeting.
  @Test
  func aLaterTrivialTurnCannotWipeTheAnswerWorthDrawing() {
    let diagram = """
      ```mermaid
      flowchart TD
        A([Start]) --> B[Run make check]
      ```
      """
    var builder = SummaryBeatBuilder()
    builder.noteUserTurn(at: at(0))
    builder.noteNarration("Let me trace how the gate runs.", at: at(1))
    builder.noteNarration(diagram, at: at(2))
    builder.noteTurnEnd()
    builder.noteUserTurn(at: at(3))
    builder.noteNarration("Anything else?", at: at(4))
    builder.noteTurnEnd()

    _ = builder.beats()
    #expect(builder.closingAnswer() == diagram)
  }

  /// An answer that is nothing but a table makes no beat — and must still be carried, or
  /// the capture happens after a guard that refuses exactly the answers worth drawing.
  @Test
  func anAnswerWithNoProseInItIsStillCarried() {
    let table = "| File | Lines |\n|---|---|\n| a.swift | 438 |"
    var builder = SummaryBeatBuilder()
    builder.noteNarration(table, at: at(1))
    builder.noteTurnEnd()
    #expect(builder.closingAnswer() == table)
  }

  /// The rail shows sentences. A table row is not one — real rails printed
  /// `| File | Actual | Limit |` where a beat belongs.
  @Test
  func aBeatIsProseRatherThanTheShapeOfTheAnswer() {
    #expect(SummaryBeatBuilder.condense("| File | Lines |\n|---|---|\n| a | 1 |") == nil)
    #expect(SummaryBeatBuilder.condense("```mermaid\nflowchart TD\n  A --> B\n```") == nil)
    // Prose around a diagram still makes its beat from the prose.
    #expect(
      SummaryBeatBuilder.condense("Here is the gate:\n\n```mermaid\nflowchart TD\n```")
        == "Here is the gate")
  }

  /// **The two ends of the cap disagreed.** An answer is cut from the front and the parser
  /// prefers the *last* fenced block, so an agent that explained itself and then drew the
  /// diagram — which is what an agent asked for a diagram does — had the diagram cut off
  /// and the explanation kept. Four thousand characters is what covers that shape.
  @Test
  func aLongAnswerKeepsTheDiagramItEndsWith() {
    var builder = SummaryBeatBuilder()
    let diagram = "```mermaid\nflowchart TD\n  A[One] --> B[Two]\n```"
    let answer =
      String(repeating: "Explaining the work in some detail. ", count: 90) + "\n\n"
      + diagram
    #expect(answer.count < SummaryBeatBuilder.maxClosing)
    builder.noteNarration(answer, at: at(1))
    builder.noteTurnEnd()

    let kept = builder.closingAnswer()
    #expect(kept?.hasSuffix("```") == true)
    #expect(MermaidBoardParser.board(fromReply: kept ?? "", pass: 1)?.nodes.count == 2)
  }

  /// Half a flowchart drawn as a whole one is worse than no flowchart: a cut that lands
  /// inside a fence drops the fence rather than leaving it hanging open.
  @Test
  func aCutThatLandsInsideAFenceDropsTheFence() {
    let prose = String(repeating: "Line of explanation.\n", count: 260)
    let clipped = SummaryBeatBuilder.clipped(
      prose + "```mermaid\nflowchart TD\n" + String(repeating: "  A --> B\n", count: 400) + "```")
    #expect(clipped.count <= SummaryBeatBuilder.maxClosing)
    #expect(!clipped.contains("```"))
    // And it stops on a line boundary rather than mid-sentence.
    #expect(clipped.hasSuffix("Line of explanation."))
  }
}
