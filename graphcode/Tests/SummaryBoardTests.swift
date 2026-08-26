import Foundation
import Testing

@testable import GraphcodeKit

/// What the board pipeline costs, which is the only interesting thing about it.
///
/// Every assertion here is about a call *not* being made. The reading behind the summary
/// rail is free and can be taken every fifteen seconds forever; a board is a CLI process,
/// and the three guards below — off means empty, a pass is drawn once, at most two a tick —
/// are what keep "one call per finished pass" from being a hope.
@Suite
struct SummaryBoardTests {

  private func node(_ title: String, passes: Int) -> LoopNode {
    var node = LoopNode(
      title: title, loopType: .goalBased, goal: GoalSpec(summary: "done"), state: .running)
    node.summary = LoopSummary(
      beats: [
        SummaryBeat(
          id: "\(title)-b", at: Date(timeIntervalSince1970: 10), pass: passes, kind: .editing,
          text: "Editing the thing")
      ],
      passes: (1..<max(passes, 1)).map { PassSummary(pass: $0, text: "did pass \($0)") },
      currentPass: passes)
    return node
  }

  private func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }

  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"))
    for node in nodes { graph.nodes.append(node) }
    return graph
  }

  private func attach(to store: GraphStore) async -> Int32 {
    let descriptor = open("/dev/null", O_WRONLY)
    await store.addConnection(id: UUID(), fileDescriptor: descriptor)
    return descriptor
  }

  /// Records which loops were drawn, so "what does a tick cost" is a number.
  private actor Composer {
    private(set) var asked: [String] = []
    private var answers: [String: SummaryBoard?] = [:]

    func answer(_ title: String, with board: SummaryBoard?) { answers[title] = board }

    private(set) var closings: [String?] = []

    func compose(_ node: LoopNode, _ summary: LoopSummary, _ closing: String?) -> SummaryBoard? {
      asked.append(node.title)
      closings.append(closing)
      guard let answer = answers[node.title] else {
        return SummaryBoardTests.flow(pass: summary.currentPass)
      }
      return answer
    }

    func reset() { asked = [] }
  }

  fileprivate static func flow(pass: Int) -> SummaryBoard {
    SummaryBoard(
      form: .flow,
      nodes: [BoardNode(id: "A", text: "one"), BoardNode(id: "B", text: "two")],
      edges: [BoardEdge(from: "A", to: "B")],
      source: "flowchart TD\n  A[one] --> B[two]", pass: pass,
      composedAt: Date(timeIntervalSince1970: 0))
  }

  private func store(
    _ nodes: [LoopNode], composer: Composer, enabled: @escaping @Sendable () -> Bool = { true }
  ) -> GraphStore {
    GraphStore(
      graph: graph(nodes),
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) },
      onComposeBoard: { node, summary, closing, _ in
        await composer.compose(node, summary, closing)
      },
      onBoardsEnabled: enabled)
  }

  // MARK: - The three guards

  @Test
  func aPassIsDrawnOnceHoweverManyTimesThePollComesRound() async {
    let composer = Composer()
    let store = store([node("A", passes: 3)], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await composer.asked == ["A"])
    #expect(await store.graph.nodes.first?.board?.pass == 3)

    await store.pollPresence()
    await store.pollPresence()
    #expect(await composer.asked == ["A"])
  }

  /// `NONE` is the answer the composer is *told* to give for a thin pass, and most passes
  /// get it. Without the attempt memo a declined pass would be re-asked every tick — a
  /// model call every fifteen seconds for as long as the loop stayed on that pass.
  @Test
  func aDeclinedPassIsNotAskedAgainUntilTheLoopMovesOn() async {
    let composer = Composer()
    await composer.answer("A", with: SummaryBoard?.none)
    let store = store([node("A", passes: 2)], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    await store.pollPresence()
    #expect(await composer.asked == ["A"])
    #expect(await store.graph.nodes.first?.board == nil)
  }

  @Test
  func atMostTwoLoopsAreDrawnInOneTick() async {
    let composer = Composer()
    let nodes = (1...5).map { node("L\($0)", passes: 4) }
    let store = store(nodes, composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await composer.asked.count == SummaryBoardComposer.maxPerTick)

    // The rest are not dropped, only deferred — the candidate list is sorted by how far
    // behind each board is, so nothing waits behind a loop that keeps finishing passes.
    await store.pollPresence()
    await store.pollPresence()
    #expect(await composer.asked.count == 5)
    #expect(Set(await composer.asked).count == 5)
  }

  @Test
  func aLoopWithNoFinishedPassIsNeverACandidate() async {
    let composer = Composer()
    let store = store([node("A", passes: 1)], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await composer.asked.isEmpty)
  }

  /// The counterpart of `turningTheProducerOffEmptiesEveryNodeItFilled` in
  /// `PresencePollingTests`: a picture left on a node for a feature nobody has switched on
  /// is the same failure as a beat left on one.
  @Test
  func turningTheExperimentOffEmptiesEveryBoardItDrew() async {
    let composer = Composer()
    let enabled = LockedBool(true)
    let store = store([node("A", passes: 3)], composer: composer, enabled: { enabled.value })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await store.graph.nodes.first?.board != nil)

    enabled.value = false
    await store.pollPresence()
    #expect(await store.graph.nodes.first?.board == nil)

    // And switching it back on draws the pass the loop is on rather than waiting for the
    // next one — the attempt memo is forgotten along with the boards.
    enabled.value = true
    await store.pollPresence()
    #expect(await store.graph.nodes.first?.board?.pass == 3)
  }

  @Test
  func aNewPassRedrawsTheBoard() async {
    let composer = Composer()
    var first = node("A", passes: 2)
    first.board = Self.flow(pass: 1)
    let store = store([first], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await store.graph.nodes.first?.board?.pass == 2)
  }

  /// **The memo must not outlive the loops it is about.** It is keyed by node id and only
  /// ever written to; without a prune, every loop ever created leaves an entry behind and a
  /// daemon that runs for weeks accumulates one per deletion. Small each — and the PTY leak
  /// this path already had was one descriptor each.
  @Test
  func theAttemptMemoIsPrunedWhenALoopIsDeleted() async {
    let composer = Composer()
    let doomed = node("A", passes: 3)
    let store = store([doomed, node("B", passes: 3)], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await store.boardAttempts.count == 2)

    await store.handle(.deleteNode(doomed.id))
    await store.pollPresence()

    #expect(await store.boardAttempts.keys.contains(doomed.id) == false)
    #expect(await store.boardAttempts.count == 1)
  }

  // MARK: - What the composer is actually given

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

  @Test
  func theAnswerReachesThePromptAndTheComposer() async {
    let composer = Composer()
    let store = store([node("A", passes: 3)], composer: composer)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    // Nothing has fed this store a reading, so there is no answer to pass on — the point is
    // that the parameter exists and is threaded, not that this fixture has one.
    #expect(await composer.closings.count == 1)

    let written = SummaryBoardComposer.prompt(
      node: node("A", passes: 3), summary: LoopSummary(currentPass: 3),
      closing: "| File | Lines |\n|---|---|\n| a.swift | 438 |")
    #expect(written.contains("What it said when it finished, in full:"))
    #expect(written.contains("| a.swift | 438 |"))
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

  // MARK: - The type's own bounds

  @Test
  func aBoardIsBoundedByConstruction() {
    let board = SummaryBoard(
      form: .table,
      table: BoardTable(
        headers: (0..<9).map { "h\($0)" },
        rows: (0..<40).map { row in (0..<9).map { "r\(row)c\($0)" } }),
      source: "", pass: 1)

    #expect(board.table?.headers.count == SummaryBoard.maxColumns)
    #expect(board.table?.rows.count == SummaryBoard.maxRows)
    #expect(board.table?.rows.allSatisfy { $0.count == SummaryBoard.maxColumns } == true)
  }

  /// A graph file written by a build that did not know about boards, and one written by a
  /// build after this one, both have to load — `ProjectPersistence` turns any decode
  /// failure into "no saved graph".
  @Test
  func aNodeWithoutABoardStillDecodes() throws {
    // The key removed rather than a graph file hand-written: what is being asserted is that
    // *this* field is optional on the way in, not that the whole encoding is stable.
    var node = LoopNode(title: "A")
    node.board = Self.flow(pass: 1)
    let data = try JSONEncoder().encode(node)
    var object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["board"] != nil)
    object.removeValue(forKey: "board")

    let older = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(LoopNode.self, from: older).board == nil)
  }

  @Test
  func aBoardSurvivesARoundTrip() throws {
    let board = Self.flow(pass: 4)
    var node = LoopNode(title: "A")
    node.board = board
    let data = try JSONEncoder().encode(node)
    let decoded = try JSONDecoder().decode(LoopNode.self, from: data)
    #expect(decoded.board == board)
  }
}

/// A `Bool` two isolation domains can share. The store reads the switch from its own actor
/// and the test flips it from outside, which is exactly the daemon's own arrangement.
private final class LockedBool: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Bool

  init(_ value: Bool) { storage = value }

  var value: Bool {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}
