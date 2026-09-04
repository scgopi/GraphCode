import Foundation
import Testing

@testable import GraphcodeKit

/// `/rename` inside a session, and the loop it renames (#261).
///
/// Two halves, tested apart. Reading a session's chosen name out of the transcript is a
/// question about one record type among a dozen, and applying it is a question about how
/// often — the poll runs every fifteen seconds and a title is a human's to keep, so a rule
/// that applied what it saw would undo the human on the next tick.
@Suite
struct SessionRenameTests {

  // MARK: - Reading the name out of a transcript

  private func lines(_ objects: [String]) -> [Data] {
    objects.compactMap { $0.data(using: .utf8) }
  }

  @Test
  func theLastCustomTitleWins() {
    // Claude Code re-emits the record at every checkpoint rather than once at the rename,
    // so a tail carries the whole history of one and only the newest is the answer.
    let found = ClaudeSessionLog.customTitle(
      inLines: lines([
        #"{"type":"custom-title","customTitle":"first","sessionId":"s"}"#,
        #"{"type":"assistant","message":{"content":[]}}"#,
        #"{"type":"custom-title","customTitle":"second","sessionId":"s"}"#,
      ]))
    #expect(found == "second")
  }

  /// The distinction the whole feature rests on.
  ///
  /// Every session carries an `agent-name` record holding a name the CLI assigned itself —
  /// `angleReuse2` and the like — and it is present in sessions nobody has ever renamed.
  /// Reading it as a rename would retitle most of a graph to strings no human typed, which
  /// is a far worse bug than the one being fixed.
  @Test
  func anAgentNameIsNotARename() {
    let found = ClaudeSessionLog.customTitle(
      inLines: lines([
        #"{"type":"agent-name","agentName":"angleReuse2","sessionId":"s"}"#
      ]))
    #expect(found == nil)
  }

  @Test
  func aBlankTitleIsNotARename() {
    let found = ClaudeSessionLog.customTitle(
      inLines: lines([
        #"{"type":"custom-title","customTitle":"named","sessionId":"s"}"#,
        #"{"type":"custom-title","customTitle":"   ","sessionId":"s"}"#,
      ]))
    #expect(found == "named")
  }

  @Test
  func aTranscriptNobodyRenamedSaysNothing() {
    let found = ClaudeSessionLog.customTitle(
      inLines: lines([
        #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        #"not json at all"#,
      ]))
    #expect(found == nil)
  }

  /// The two halves `sessionTitle` composes, over a file shaped like a real transcript:
  /// checkpoint records repeated as the session runs, each `custom-title` paired with the
  /// `agent-name` that must not be mistaken for it, and the rename arriving partway
  /// through rather than at the top.
  @Test
  func theTailReadFindsTheNameInARealisticTranscript() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-rename-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("transcript.jsonl")

    var records = [#"{"type":"agent-name","agentName":"angleReuse2","sessionId":"s"}"#]
    for _ in 0..<3 {
      records.append(#"{"type":"assistant","message":{"content":[],"stop_reason":"end_turn"}}"#)
      records.append(#"{"type":"agent-name","agentName":"angleReuse2","sessionId":"s"}"#)
    }
    for _ in 0..<3 {
      records.append(#"{"type":"custom-title","customTitle":"hello","sessionId":"s"}"#)
      records.append(#"{"type":"agent-name","agentName":"hello","sessionId":"s"}"#)
    }
    try records.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    #expect(ClaudeSessionLog.customTitle(inLines: SummaryBeatBuilder.tailLines(of: url)) == "hello")
  }

  /// A remote loop's transcript is on the other machine, and this must not go looking for
  /// it: every reading of one costs an ssh probe per node per poll, which is a price worth
  /// paying for a rail that changes every few seconds and not for a name that changes when
  /// somebody types six characters.
  @Test
  func aRemoteLoopIsNotProbed() async {
    let node = LoopNode(title: "Remote", loopType: .goalBased, goal: GoalSpec(summary: "done"))
    #expect(
      await ClaudeSessionLog.sessionTitle(of: node, projectPath: "ssh://host/srv/repo") == nil)
    #expect(
      await ClaudeSessionLog.sessionTitle(
        of: node, projectPath: "codespace://humble-dollop/repo") == nil)
  }

  // MARK: - Applying it to the loop

  private func node(_ title: String, _ state: LoopState = .running) -> LoopNode {
    LoopNode(title: title, loopType: .goalBased, goal: GoalSpec(summary: "done"), state: state)
  }

  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"))
    for node in nodes { graph.nodes.append(node) }
    return graph
  }

  /// `addConnection` broadcasts immediately and drops a connection it cannot write to, so
  /// a placeholder descriptor would leave the store clientless and `pollPresence` would
  /// return before doing anything — every assertion below passing for the wrong reason.
  private func attach(to store: GraphStore) async -> Int32 {
    let descriptor = open("/dev/null", O_WRONLY)
    await store.addConnection(id: UUID(), fileDescriptor: descriptor)
    return descriptor
  }

  private func store(
    _ nodes: [LoopNode], titles: TitleProbe, onGraphChanged: (@Sendable (LoopGraph) -> Void)? = nil
  ) -> GraphStore {
    GraphStore(
      graph: graph(nodes),
      onGraphChanged: onGraphChanged,
      onReadSessionTitle: { node, _ in await titles.read(node) },
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) })
  }

  @Test
  func aRenamedSessionRenamesItsLoop() async {
    let titles = TitleProbe()
    await titles.answer("New Loop", with: "hello")
    let store = store([node("New Loop")], titles: titles)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await store.graph.nodes[0].title == "hello")
    #expect(await store.graph.nodes[0].sessionTitle == "hello")
  }

  /// The guard that makes this safe to run every fifteen seconds.
  ///
  /// Once a name has been applied, the card is the human's again. Renaming it from the
  /// sidebar has to stick — and it only can because the node remembers what the *session*
  /// was called, which is no longer what the node is called.
  @Test
  func aRenameFromTheSidebarSurvivesTheNextPoll() async {
    let titles = TitleProbe()
    await titles.answer("New Loop", with: "hello")
    let store = store([node("New Loop")], titles: titles)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }
    await store.pollPresence()

    let nodeID = await store.graph.nodes[0].id
    await store.handle(.renameNode(nodeID, title: "Chosen By Hand"))
    // The session still says the same thing it said before; nothing has changed but time.
    await titles.answer("Chosen By Hand", with: "hello")
    await store.pollPresence()

    #expect(await store.graph.nodes[0].title == "Chosen By Hand")
  }

  @Test
  func aSecondSessionRenameStillWins() async {
    let titles = TitleProbe()
    await titles.answer("New Loop", with: "hello")
    let store = store([node("New Loop")], titles: titles)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }
    await store.pollPresence()

    await titles.answer("hello", with: "hello again")
    await store.pollPresence()

    #expect(await store.graph.nodes[0].title == "hello again")
  }

  /// Unlike every other reading on the poll, this one has to reach disk.
  ///
  /// The title is the node's own, and `sessionTitle` is what stops the following tick
  /// applying the same rename a second time. Broadcast to clients but never saved, both
  /// would be gone at the next daemon restart — and the rename would land again as new,
  /// overwriting whatever the human had renamed the card to in between.
  @Test
  func aSessionRenameIsPersistedThoughThePollUsuallyIsNot() async {
    let titles = TitleProbe()
    await titles.answer("New Loop", with: "hello")
    let saved = GraphBox()
    let store = store(
      [node("New Loop")], titles: titles,
      onGraphChanged: { graph in Task { await saved.record(graph) } })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await saved.awaitTitle("hello"))
  }

  /// A resolved loop's session is over, so it cannot be renamed — and asking anyway costs
  /// a walk of every project directory on the machine, per node, every fifteen seconds.
  @Test
  func aResolvedLoopIsNotAsked() async {
    let titles = TitleProbe()
    let store = store([node("Done", .succeeded)], titles: titles)
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await titles.asked.isEmpty)
  }

  private actor TitleProbe {
    private var answers: [String: String] = [:]
    private(set) var asked: [String] = []

    func answer(_ title: String, with sessionTitle: String) { answers[title] = sessionTitle }

    func read(_ node: LoopNode) -> String? {
      asked.append(node.title)
      return answers[node.title]
    }
  }

  private actor GraphBox {
    private var graphs: [LoopGraph] = []

    func record(_ graph: LoopGraph) { graphs.append(graph) }

    func awaitTitle(_ title: String, attempts: Int = 50) async -> Bool {
      for _ in 0..<attempts {
        if graphs.contains(where: { $0.nodes.contains(where: { $0.title == title }) }) {
          return true
        }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return false
    }
  }
}
