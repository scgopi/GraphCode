import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// What a table cell is taken to be, which is the half of the table renderer that can be
/// wrong about something.
///
/// Drawing a cell as a green tick is a *claim* that it is a verdict, and the interesting
/// cases here are all the near-misses: the word `pass` inside a phrase, a bare number that
/// is not a diffstat, a column that is numeric except for one `n/a`.
@Suite
struct BoardTablePresentationTests {

  private func table(
    _ headers: [String], _ rows: [[String]], alignments: [BoardColumnAlignment] = []
  ) -> BoardTablePresentation {
    BoardTablePresentation(
      table: BoardTable(headers: headers, rows: rows, alignments: alignments))
  }

  // MARK: - Columns

  @Test
  func aColumnIsNumericOnlyWhenEveryCellIs() {
    let clean = table(["File", "Lines"], [["a.swift", "438"], ["b.swift", "12"]])
    #expect(clean.columns.map(\.isNumeric) == [false, true])

    // One `n/a` and the column stops being a column of numbers — otherwise a single stray
    // cell leaves the rest right-aligned around nothing.
    let ragged = table(["File", "Lines"], [["a.swift", "438"], ["b.swift", "n/a"]])
    #expect(ragged.columns.map(\.isNumeric) == [false, false])
  }

  @Test
  func numbersGoRightUnlessTheAuthorSaidOtherwise() {
    let inferred = table(["File", "Lines"], [["a", "1"], ["b", "2"]])
    #expect(inferred.columns.map(\.effectiveAlignment) == [.leading, .trailing])

    // The separator row always wins: it is the author being explicit, and the parser has
    // read it since before boards could draw a table properly.
    let stated = table(
      ["File", "Lines"], [["a", "1"], ["b", "2"]], alignments: [.center, .leading])
    #expect(stated.columns.map(\.effectiveAlignment) == [.center, .leading])
  }

  @Test
  func barsNeedEnoughRowsAndSomeActualSpread() {
    #expect(table(["N"], [["1"], ["9"]]).columns[0].showsBars == false)
    #expect(table(["N"], [["4"], ["4"], ["4"]]).columns[0].showsBars == false)
    #expect(table(["N"], [["1"], ["5"], ["9"]]).columns[0].showsBars)
  }

  /// A bar compares a value with its own column, never with the table — otherwise a column
  /// of percentages beside a column of line counts draws every percentage as empty.
  @Test
  func aBarIsScaledWithinItsOwnColumn() throws {
    let subject = table(
      ["Small", "Large"], [["1", "1000"], ["5", "5000"], ["9", "9000"]])
    guard case .number(_, let small) = subject.rows[1][0],
      case .number(_, let large) = subject.rows[1][1]
    else {
      Issue.record("expected two numeric cells")
      return
    }
    #expect(try #require(small) == 0.5)
    #expect(try #require(large) == 0.5)
  }

  // MARK: - Cells

  @Test
  func theWordsAVerdictIsWrittenInAreRecognised() {
    for word in ["yes", "PASS", "ok", "true", "✅", "clean"] {
      #expect(BoardTablePresentation.verdict(of: word) == true, "\(word)")
    }
    for word in ["no", "FAIL", "error", "false", "❌", "broken"] {
      #expect(BoardTablePresentation.verdict(of: word) == false, "\(word)")
    }
  }

  /// **The one that would be actively misleading.** `pass` is a verdict; `pass 3` is a
  /// phrase about which pass, and a column of pass numbers drawn as green ticks is exactly
  /// the confidently-wrong rendering this whole feature is meant to avoid.
  @Test
  func aVerdictWordInsideAPhraseIsNotAVerdict() {
    #expect(BoardTablePresentation.verdict(of: "pass 3") == nil)
    #expect(BoardTablePresentation.verdict(of: "no changes") == nil)
    #expect(BoardTablePresentation.verdict(of: "okay then") == nil)

    let subject = table(["Pass", "Result"], [["pass 3", "pass"], ["pass 4", "fail"]])
    #expect(subject.rows[0][0] == .plain("pass 3"))
    #expect(subject.rows[0][1] == .verdict(true, "pass"))
    #expect(subject.rows[1][1] == .verdict(false, "fail"))
  }

  @Test
  func onlyASignedNumberIsADiffstat() {
    let subject = table(["File", "Change"], [["a", "+52"], ["b", "-9"], ["c", "52"]])
    #expect(subject.rows[0][1] == .delta(isAddition: true, text: "+52"))
    #expect(subject.rows[1][1] == .delta(isAddition: false, text: "-9"))
    // A bare count is never a delta, so a column of plain numbers is left alone.
    if case .delta = subject.rows[2][1] {
      Issue.record("52 was read as a diffstat")
    }
  }

  @Test
  func numbersArePickedOutOfTheFormsPeopleWriteThemIn() {
    #expect(BoardTablePresentation.number(from: "1,024") == 1024)
    #expect(BoardTablePresentation.number(from: "93%") == 93)
    #expect(BoardTablePresentation.number(from: "1.4k") == 1400)
    #expect(BoardTablePresentation.number(from: "250ms") == 250)
    #expect(BoardTablePresentation.number(from: "−9") == -9)
    #expect(BoardTablePresentation.number(from: "GraphStore.swift") == nil)
    #expect(BoardTablePresentation.number(from: "3 files") == nil)
    #expect(BoardTablePresentation.number(from: "") == nil)
  }

  /// A table is Markdown wherever it is pasted; a Mermaid fence around one makes every
  /// reader draw it as a failed diagram.
  @Test
  func aTableIsCopiedAsMarkdownAndAFlowAsMermaid() {
    let table = SummaryBoard(
      form: .table, table: BoardTable(headers: ["A"], rows: [["1"]]),
      source: "| A |\n|---|\n| 1 |", pass: 1)
    #expect(SummaryBoardSection.pasteboardText(for: table) == "| A |\n|---|\n| 1 |")

    let flow = SummaryBoard(
      form: .flow, nodes: [BoardNode(id: "A", text: "One"), BoardNode(id: "B", text: "Two")],
      edges: [BoardEdge(from: "A", to: "B")], source: "flowchart TD\n  A --> B", pass: 1)
    #expect(
      SummaryBoardSection.pasteboardText(for: flow)
        == "```mermaid\nflowchart TD\n  A --> B\n```")
  }
}
