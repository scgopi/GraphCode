import Foundation
import Testing

@testable import GraphcodeKit

/// The board an agent drew for itself.
///
/// The cheapest and most faithful case, and the one a person hits deliberately: asking a
/// session for a diagram and getting one back. Rendering it verbatim spends nothing, takes
/// no time, and cannot drift from what the session actually said — where handing it to a
/// model to be written again does all three.
@Suite
struct AgentDrawnBoardTests {

  /// **The cheapest and most faithful case.** When the agent has already written the
  /// diagram — which is what happens when a human asks for one — it is rendered verbatim
  /// and no model is invoked at all.
  @Test
  func anAgentsOwnDiagramIsRenderedWithoutAModel() throws {
    let answer = """
      Here is how the release gate works:

      ```mermaid
      flowchart TD
        A([Start]) --> B[Run make check]
        B --> C{Green?}
        C -->|yes| D([Ship])
        C -->|no| B
      ```

      The retry is the important part.
      """
    let board = try #require(
      SummaryBoardComposer.drawnByTheAgent(
        answer, pass: 4, now: Date(timeIntervalSince1970: 0)))

    #expect(board.form == .flow)
    #expect(board.nodes.count == 4)
    #expect(board.pass == 4)
    // Verbatim: the source is the agent's own block, not a model's restatement of it.
    #expect(board.source.contains("C -->|no| B"))
  }

  @Test
  func anAgentsOwnTableIsRenderedWithoutAModel() throws {
    let board = try #require(
      SummaryBoardComposer.drawnByTheAgent(
        """
        Four files are over their limits:

        | File | Actual | Limit |
        |---|---|---|
        | RemoteSessionResumeTests.swift | 438 | 400 |
        | CheckForUpdatesTests.swift | 414 | 400 |
        """, pass: 2, now: Date(timeIntervalSince1970: 0)))

    #expect(board.form == .table)
    #expect(board.table?.rows.count == 2)
  }

  /// Prose alone is not a board, and must fall through to the composer rather than being
  /// forced into one.
  @Test
  func anAnswerWithNoDiagramInItFallsThroughToTheComposer() {
    let now = Date(timeIntervalSince1970: 0)
    #expect(SummaryBoardComposer.drawnByTheAgent(nil, pass: 1, now: now) == nil)
    #expect(SummaryBoardComposer.drawnByTheAgent("", pass: 1, now: now) == nil)
    #expect(
      SummaryBoardComposer.drawnByTheAgent(
        "I read the probe and trimmed the preamble. Nothing else changed.",
        pass: 1, now: now) == nil)
    // A lone box is drawable Mermaid but not worth the rail's space.
    #expect(
      SummaryBoardComposer.drawnByTheAgent(
        "```mermaid\nflowchart TD\n  A[Only this]\n```", pass: 1, now: now) == nil)
  }
}
