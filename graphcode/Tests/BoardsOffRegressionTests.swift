import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// What the app does when nobody has switched the experiment on — which is every install
/// by default, and therefore the only behaviour most people will ever see.
///
/// The bar is not "the feature is hidden". It is that **nothing observable changed**: no
/// process is spawned, no byte is added to a graph file, no extra broadcast is sent, and
/// every surface answers exactly what it answered before boards existed. A dormant feature
/// that still costs a subprocess, or still marks the graph dirty every fifteen seconds, has
/// regressed the app for the people who never asked for it.
@Suite
struct BoardsOffRegressionTests {

  private func node(_ title: String, passes: Int) -> LoopNode {
    var node = LoopNode(
      title: title, loopType: .goalBased, goal: GoalSpec(summary: "done"), state: .running)
    node.summary = LoopSummary(
      beats: [
        SummaryBeat(
          id: "\(title)-b", at: Date(timeIntervalSince1970: 10), pass: passes,
          kind: .editing, text: "Editing the thing")
      ],
      passes: (1..<max(passes, 1)).map { PassSummary(pass: $0, text: "did pass \($0)") },
      currentPass: passes)
    return node
  }

  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"))
    for node in nodes { graph.nodes.append(node) }
    return graph
  }

  private actor Probe {
    private(set) var asked = 0
    func compose() -> SummaryBoard? {
      asked += 1
      return nil
    }
  }

  /// Counts what the daemon tells its clients, which is also what it writes to disk.
  private final class Writes: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
  }

  // MARK: - Nothing runs

  @Test
  func noComposerIsEverInvokedAndNoBoardIsEverSet() async {
    let probe = Probe()
    let store = GraphStore(
      graph: graph([node("A", passes: 4), node("B", passes: 7)]),
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) },
      onComposeBoard: { _, _, _, _ in await probe.compose() },
      onBoardsEnabled: { false })
    let descriptor = open("/dev/null", O_WRONLY)
    await store.addConnection(id: UUID(), fileDescriptor: descriptor)
    defer { close(descriptor) }

    for _ in 0..<5 { await store.pollPresence() }

    #expect(await probe.asked == 0)
    #expect(await store.graph.nodes.allSatisfy { $0.board == nil })
  }

  /// **The quiet regression.** `refreshBoards` runs on every tick whether or not the
  /// experiment is on. If it reported a change it had not made, the daemon would write the
  /// graph to disk and broadcast to every client every fifteen seconds, for ever, on behalf
  /// of a feature nobody switched on — the exact cost `PresencePollingTests` exists to keep
  /// out of the poll.
  @Test
  func thePollDoesNotReportAChangeItDidNotMake() async {
    let writes = Writes()
    let store = GraphStore(
      graph: graph([node("A", passes: 4)]),
      onGraphChanged: { _ in writes.record() },
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) },
      onComposeBoard: { _, _, _, _ in nil },
      onBoardsEnabled: { false })
    let descriptor = open("/dev/null", O_WRONLY)
    await store.addConnection(id: UUID(), fileDescriptor: descriptor)
    defer { close(descriptor) }

    await store.pollPresence()
    let settled = writes.value
    for _ in 0..<5 { await store.pollPresence() }

    #expect(writes.value == settled, "the graph was written on a tick that changed nothing")
  }

  // MARK: - Nothing on screen moves

  /// The rail's own answer, with the board switch off, must be the one it gave before the
  /// board section existed: edges, or a metric series, or a beat — and nothing else.
  @Test
  func theRailOpensOnExactlyWhatItAlwaysOpenedOn() {
    var wired = node("wired", passes: 2)
    var lonely = node("lonely", passes: 2)
    // A board left on a node by a previous switch-on must not reopen the rail either.
    lonely.board = SummaryBoard(
      form: .flow,
      nodes: [BoardNode(id: "A", text: "one"), BoardNode(id: "B", text: "two")],
      edges: [BoardEdge(from: "A", to: "B")], source: "", pass: 2)
    var measured = node("measured", passes: 2)
    measured.metricHistory = [
      MetricSample(value: 1, recordedAt: Date(timeIntervalSince1970: 1)),
      MetricSample(value: 2, recordedAt: Date(timeIntervalSince1970: 2)),
    ]
    wired.summary = nil
    lonely.summary = nil
    measured.summary = nil

    var subject = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"))
    subject.nodes.append(wired)
    subject.nodes.append(lonely)
    subject.nodes.append(measured)
    subject.edges.append(LoopEdge(from: wired.id, to: measured.id, condition: .onSuccess))

    for node in [wired, lonely, measured] {
      let opens = LoopWorkspaceRail.hasContent(
        node: node, graph: subject, summarising: false, drawing: false)
      // wired has an edge, measured has two samples, lonely has neither — and a board it
      // is not allowed to count.
      #expect(opens == (node.id != lonely.id), "\(node.title)")
    }
  }

  @Test
  func theBoardSectionNeverClaimsContentWhileTheSwitchIsOff() {
    var drawn = node("drawn", passes: 3)
    drawn.board = SummaryBoard(
      form: .flow,
      nodes: [BoardNode(id: "A", text: "one"), BoardNode(id: "B", text: "two")],
      edges: [BoardEdge(from: "A", to: "B")], source: "", pass: 3)
    drawn.presence = PresenceReading(presence: .busy, confidence: .reported)

    #expect(!SummaryBoardPresentation.hasContent(node: drawn, drawing: false))
    // And with it on, the same node does — so the assertion above is about the switch and
    // not about the node being empty.
    #expect(SummaryBoardPresentation.hasContent(node: drawn, drawing: true))
  }

  // MARK: - Nothing on disk changes

  /// A graph file written by this build, for a loop that never drew a board, must carry no
  /// trace of the feature — same keys, same size, readable by the build before this one.
  @Test
  func aNodeWithoutABoardAddsNothingToTheGraphFile() throws {
    let plain = node("A", passes: 3)
    #expect(plain.board == nil)

    let data = try JSONEncoder().encode(plain)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["board"] == nil, "a nil board still wrote a key")
  }

  /// A settings file written before the key existed loads with the experiment off, and
  /// every other answer in it unchanged.
  @Test
  func anOlderSettingsFileGainsNothingButTheDefault() throws {
    var before = GraphcodeSettings()
    before.summarisesLoops = true
    before.summaryUsesModel = true
    let data = try JSONEncoder().encode(before)
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "visualisesSummaries")

    let older = try JSONSerialization.data(withJSONObject: object)
    let loaded = try JSONDecoder().decode(GraphcodeSettings.self, from: older)

    #expect(!loaded.visualisesSummaries)
    // Nothing else moved. Switching the rail on must never imply switching this on.
    #expect(loaded.summarisesLoops)
    #expect(loaded.summaryUsesModel)
    #expect(loaded.daemonHeartbeatEnabled == before.daemonHeartbeatEnabled)
  }

  @Test
  func aFreshSettingsFileHasTheExperimentOff() {
    #expect(!GraphcodeSettings().visualisesSummaries)
  }
}
