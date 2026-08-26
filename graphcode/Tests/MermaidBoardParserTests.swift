import Foundation
import Testing

@testable import GraphcodeKit

/// What the composer is allowed to write, and what happens to everything else.
///
/// The parser is the one place in the board pipeline where a model's free text becomes a
/// structure the app draws, so the interesting cases are all the ones where the reply is
/// nearly right: a banner in front of it, a fence it forgot to close, a diagram type
/// nobody asked for, a table with a cell missing.
@Suite
struct MermaidBoardParserTests {

  private func board(_ reply: String, pass: Int = 3) -> SummaryBoard? {
    MermaidBoardParser.board(
      fromReply: reply, pass: pass, now: Date(timeIntervalSince1970: 0))
  }

  // MARK: - Flowcharts

  @Test
  func aFlowchartBecomesBoxesAndArrows() throws {
    let parsed = try #require(
      board(
        """
        ```mermaid
        %% title: The release gate
        flowchart TD
          A([Start]) --> B[Run make check]
          B --> C{Green?}
          C -->|yes| D([Ship it])
          C -->|no| B
        ```
        """))

    #expect(parsed.form == .flow)
    #expect(parsed.title == "The release gate")
    #expect(parsed.direction == .topDown)
    #expect(parsed.nodes.map(\.id) == ["A", "B", "C", "D"])
    #expect(parsed.nodes.map(\.text) == ["Start", "Run make check", "Green?", "Ship it"])
    #expect(parsed.nodes.map(\.shape) == [.terminal, .box, .decision, .terminal])
    #expect(
      parsed.edges.map { "\($0.from)\($0.label.map { label in "|\(label)|" } ?? "")\($0.to)" }
        == ["AB", "BC", "C|yes|D", "C|no|B"])
    // The pass is the store's, never the model's — nothing in the reply above set it.
    #expect(parsed.pass == 3)
  }

  /// The label belongs to the link *before* the node it is read against, which is the one
  /// off-by-one this parser can make and the reason chains are tested rather than assumed.
  @Test
  func aChainedLineKeepsEachLabelOnItsOwnArrow() throws {
    let parsed = try #require(
      board(
        """
        flowchart LR
          A[One] -->|first| B[Two] -->|second| C[Three]
        """))

    #expect(parsed.direction == .leftRight)
    #expect(parsed.edges.map(\.label) == ["first", "second"])
    #expect(parsed.edges.map(\.from) == ["A", "B"])
    #expect(parsed.edges.map(\.to) == ["B", "C"])
  }

  @Test
  func bothSpellingsOfAnEdgeLabelAreRead() throws {
    let parsed = try #require(
      board(
        """
        flowchart TD
          A[a] -- no --> B[b]
          B -.-> C[c]
          C == the spine ==> D[d]
          D --- E[e]
        """))

    #expect(parsed.edges.map(\.label) == ["no", nil, "the spine", nil])
    #expect(parsed.edges.map(\.style) == [.solid, .dashed, .thick, .solid])
  }

  /// A node named once with a label and again without keeps the label. Mermaid's own
  /// convention, and taking the later mention would blank half a diagram.
  @Test
  func aLaterBareMentionDoesNotBlankALabel() throws {
    let parsed = try #require(
      board(
        """
        flowchart TD
          A[Read the transcript] --> B[Fold it in]
          B --> A
        """))

    #expect(parsed.nodes.first { $0.id == "A" }?.text == "Read the transcript")
  }

  @Test
  func quotedLabelsAndLineBreaksAreTheSyntaxNotTheText() throws {
    let parsed = try #require(
      board(
        """
        flowchart TD
          A["Read UsageProbe.swift, twice"] --> B["One<br/>two"]
        """))

    #expect(parsed.nodes.map(\.text) == ["Read UsageProbe.swift, twice", "One two"])
  }

  @Test
  func stylingDirectivesAreDroppedRatherThanRefused() throws {
    let parsed = try #require(
      board(
        """
        flowchart TD
          subgraph one
          A[a] --> B[b]
          end
          classDef big fill:#f00
          class A big
          linkStyle 0 stroke:#fff
          click A "https://example.com"
        """))

    #expect(parsed.nodes.map(\.id) == ["A", "B"])
    #expect(parsed.edges.count == 1)
  }

  // MARK: - What is refused

  @Test
  func aDiagramTypeOutsideTheSubsetIsNotABoard() {
    #expect(
      board(
        """
        ```mermaid
        sequenceDiagram
          Alice->>Bob: Hello
        ```
        """) == nil)
  }

  /// One box and no arrows is a sentence in a rectangle, and the summary above the board
  /// already says it better — see `SummaryBoard.isDrawable`.
  @Test
  func aSingleBoxIsNotWorthDrawing() {
    #expect(board("flowchart TD\n  A[Only this]") == nil)
  }

  @Test
  func anEdgeIntoNothingIsDroppedRatherThanDrawnToNowhere() throws {
    // 24 boxes is the cap; the 25th and every arrow reaching it must go together.
    var lines = ["flowchart TD"]
    for index in 0..<30 { lines.append("  N\(index)[step \(index)] --> N\(index + 1)[step]") }
    let parsed = try #require(board(lines.joined(separator: "\n")))

    #expect(parsed.nodes.count == SummaryBoard.maxNodes)
    let known = Set(parsed.nodes.map(\.id))
    #expect(parsed.edges.allSatisfy { known.contains($0.from) && known.contains($0.to) })
  }

  // MARK: - What a real model actually writes

  /// Verbatim `claude -p --model haiku` output for the composer's own prompt, over a run
  /// that genuinely branched — the release loop that hit a notarisation rejection, a
  /// blocked merge and a non-fast-forward push.
  ///
  /// Fixtures written by hand test the parser against what its author imagined; this tests
  /// it against what the fast tier does when nobody is watching. It is also the only case
  /// here with two independent retry loops in it, which is what the layout's cycle-breaking
  /// exists for.
  @Test
  func theFastTiersOwnOutputParses() throws {
    let parsed = try #require(
      board(
        """
        ```mermaid
        flowchart TD
          A([Start]) --> B["Bump version, push main"]
          B --> C["Build DMG"]
          C --> D["Notarise"]
          D --> E{Pass?}
          E -->|No| F["Re-sign helpers"]
          F --> C
          E -->|Yes| G["Try gh pr merge"]
          G --> H{Allowed?}
          H -->|No| I["Use git merge"]
          H -->|Yes| I
          I --> J["Push to tap"]
          J --> K{Fast-forward?}
          K -->|No| L["Re-clone tap"]
          L --> J
          K -->|Yes| M([Done])
        ```
        """))

    #expect(parsed.nodes.count == 13)
    #expect(parsed.edges.count == 15)
    #expect(
      parsed.nodes.filter { $0.shape == .decision }.map(\.text) == [
        "Pass?", "Allowed?", "Fast-forward?",
      ])
    #expect(parsed.nodes.filter { $0.shape == .terminal }.map(\.id) == ["A", "M"])
    // The comma inside a quoted label is the label's, not the diagram's.
    #expect(parsed.nodes.first { $0.id == "B" }?.text == "Bump version, push main")
    #expect(parsed.edges.filter { $0.label == "No" }.count == 3)
  }

  /// The same prompt against a run of findings. The separator row here has no colons and
  /// the cells carry bare numbers — what a model writes when asked for a table, rather than
  /// the fully-aligned form a person writes.
  @Test
  func theFastTiersOwnTableParses() throws {
    let parsed = try #require(
      board(
        """
        | Test | Lines | Limit |
        |---|---|---|
        | RemoteSessionResumeTests | 438 | 400 |
        | CheckForUpdatesTests | 414 | 400 |
        | NodeDraftTests | 259 | 250 |
        | RemoteCLIShimTests | 61 | 50 |
        """))

    #expect(parsed.form == .table)
    #expect(parsed.table?.rows.count == 4)
    #expect(parsed.table?.rows.last == ["RemoteCLIShimTests", "61", "50"])
  }

  // MARK: - Fences and noise

  @Test
  func theLastBlockWinsOverAnyBannerBeforeIt() throws {
    let parsed = try #require(
      board(
        """
        Welcome to the CLI. Reading config…
        Here is a diagram of what happened:

        ```mermaid
        flowchart TD
          A[a] --> B[b]
        ```
        """))

    #expect(parsed.nodes.count == 2)
  }

  @Test
  func anUnclosedFenceIsStillAnAnswer() throws {
    let parsed = try #require(
      board(
        """
        ```mermaid
        flowchart TD
          A[a] --> B[b]
        """))

    #expect(parsed.nodes.count == 2)
  }
}

/// The other half of the subset: a Markdown table, and the separator row that says which
/// way each column reads.
///
/// Its own suite rather than more of the one above — they share no fixture, and the flow
/// cases are the ones with the syntax in them.
@Suite
struct MermaidTableParserTests {

  private func board(_ reply: String, pass: Int = 3) -> SummaryBoard? {
    MermaidBoardParser.board(
      fromReply: reply, pass: pass, now: Date(timeIntervalSince1970: 0))
  }

  @Test
  func aMarkdownTableBecomesRowsAndColumns() throws {
    let parsed = try #require(
      board(
        """
        | File | Change | Lines |
        |---|---:|---|
        | GraphStore.swift | refreshBoards | +52 |
        | LoopNode.swift | board field | +9 |
        """))

    #expect(parsed.form == .table)
    #expect(parsed.table?.headers == ["File", "Change", "Lines"])
    #expect(parsed.table?.rows.count == 2)
    #expect(parsed.table?.rows.first == ["GraphStore.swift", "refreshBoards", "+52"])
  }

  @Test
  func aShortRowIsPaddedRatherThanCrashingTheColumnIndex() throws {
    let parsed = try #require(
      board(
        """
        | A | B | C |
        |---|---|---|
        | one | two |
        """))

    #expect(parsed.table?.normalisedRows == [["one", "two", ""]])
  }

  /// The separator row is required. Without it a flowchart line carrying a pipe parses as
  /// a one-row table, and a board that draws the wrong *form* is worse than no board.
  @Test
  func pipesWithoutASeparatorAreNotATable() {
    #expect(
      board(
        """
        | just | some | text |
        | more | of   | it   |
        | and  | more | yet  |
        """) == nil)
  }

  @Test
  func aTableWithNoRowsIsNotABoard() {
    #expect(board("| A | B |\n|---|---|\n|  |  |") == nil)
  }

  /// The separator row's colons are the author saying which way a column reads. The parser
  /// has always had to look at that row to know it *was* a separator; until boards could
  /// draw a table properly it threw the answer away.

  @Test
  func theSeparatorRowsColonsAreRead() {
    #expect(
      MermaidBoardParser.alignments(ofSeparator: "|---|:---|---:|:---:|")
        == [.unspecified, .leading, .trailing, .center])
  }

  @Test
  func aParsedTableCarriesItsAlignmentsThrough() throws {
    let board = try #require(
      MermaidBoardParser.board(
        fromReply: """
          | File | Lines |
          |:---|---:|
          | a.swift | 438 |
          | b.swift | 12 |
          """, pass: 1))
    #expect(board.table?.alignments == [.leading, .trailing])
  }

  /// A board written before alignments existed still draws — the list is padded to the
  /// header count on the way in rather than trusted to match.
  @Test
  func aTableWithoutAlignmentsStillDecodes() throws {
    let json = Data(#"{"headers":["A","B"],"rows":[["1","2"]]}"#.utf8)
    let decoded = try JSONDecoder().decode(BoardTable.self, from: json)
    #expect(decoded.alignments == [.unspecified, .unspecified])
    #expect(decoded.alignment(ofColumn: 5) == .unspecified)
  }
}
