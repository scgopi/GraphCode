import Foundation
import XCTest

@testable import GraphcodeKit

/// A stopped loop's session is asked to stop, not killed, so the agent's own reply to the
/// stop prompt arrives as presence readings (busy, then awaitingInput or idle). That reply
/// must not read as the loop coming back — but a human typing into the still-live pane, or
/// a restored session, is a genuine re-engagement, and a question that follows must reach
/// Needs you, `graphcode status` and every other surface that reads presence.
final class StoppedLoopPresenceTests: XCTestCase {
  private actor Answers {
    private var byTitle: [String: Presence] = [:]
    func set(_ title: String, _ presence: Presence) { byTitle[title] = presence }
    func read(_ node: LoopNode) -> PresenceReading {
      PresenceReading(presence: byTitle[node.title] ?? .idle, confidence: .reported)
    }
  }

  private actor Sink: DaemonConnection {
    nonisolated let id = UUID()
    nonisolated let endpoint: DaemonEndpoint = .namedPipe("\\\\.\\pipe\\stopped-presence-in-memory")
    func receiveFrame() async throws -> Data { throw Closed.connection }
    func sendFrame(_ data: Data) async throws {}
    func close() async throws {}
    private enum Closed: Error { case connection }
  }

  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    graph.nodes.append(contentsOf: nodes)
    return graph
  }

  private func makeStore(_ graph: LoopGraph, answers: Answers, delivers: Bool = true) async
    -> GraphStore
  {
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: delivers ? { _, _, _ in true } : nil,
      onReadPresence: { node, _ in await answers.read(node) })
    let sink = Sink()
    await store.addConnection(id: sink.id, connection: sink, mode: .v2(version: 2))
    return store
  }

  /// What a daemon restart does to a graph: it is saved, loaded, and its presence dropped.
  private func reloaded(_ graph: LoopGraph) throws -> LoopGraph {
    var loaded = try JSONDecoder().decode(LoopGraph.self, from: JSONEncoder().encode(graph))
    for index in loaded.nodes.indices { loaded.nodes[index].presence = nil }
    return loaded
  }

  private func poll(_ store: GraphStore, _ answers: Answers, _ title: String, _ answer: Presence)
    async -> LoopNode?
  {
    await answers.set(title, answer)
    await store.pollPresence()
    return await store.graph.nodes.first { $0.title == title }
  }

  private func stoppedAndSettled(_ answers: Answers) async -> (GraphStore, UUID) {
    let store = await makeStore(
      graph([LoopNode(title: "stopper", loopType: .turnBased, state: .running)]),
      answers: answers)
    let id = await store.graph.nodes[0].id
    await store.handle(.stopNode(id))
    _ = await poll(store, answers, "stopper", .busy)
    _ = await poll(store, answers, "stopper", .awaitingInput)
    return (store, id)
  }

  private func assertQuietlyStopped(
    _ node: LoopNode?, _ context: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(node?.state, .stopped, context, file: file, line: line)
    XCTAssertEqual(node?.displayState, .stopped, context, file: file, line: line)
    XCTAssertNil(node.flatMap { AttentionRollup.reason(for: $0) }, context, file: file, line: line)
  }

  func testStopReplyStaysStoppedAndOutOfNeedsYouWhileTheAgentAnswers() async {
    let answers = Answers()
    let store = await makeStore(
      graph([
        LoopNode(title: "stopper", loopType: .turnBased, state: .running),
        LoopNode(title: "sibling", loopType: .turnBased, state: .running),
      ]), answers: answers)
    let stopperID = await store.graph.nodes[0].id

    await store.handle(.stopNode(stopperID))
    let afterStop = await store.graph.nodes[id: stopperID]
    XCTAssertEqual(afterStop?.stopReply?.phase, .awaitingReply)

    await answers.set("sibling", .awaitingInput)
    for answer in [Presence.busy, .busy, .awaitingInput, .idle, .awaitingInput] {
      assertQuietlyStopped(
        await poll(store, answers, "stopper", answer), "after reading \(answer)")
    }
    let settled = await store.graph.nodes[id: stopperID]
    XCTAssertEqual(settled?.stopReply?.phase, .settled)

    // Only the stopped loop is exempt: a loop nobody stopped still asks for the human.
    let sibling = await store.graph.nodes[1]
    XCTAssertEqual(sibling.displayState, .awaitingInput)
    XCTAssertEqual(AttentionRollup.reason(for: sibling), .awaitingInput)
  }

  func testAHumanReEngagingTheSettledLoopSurfacesTheQuestion() async {
    let answers = Answers()
    let (store, id) = await stoppedAndSettled(answers)

    let working = await poll(store, answers, "stopper", .busy)
    XCTAssertEqual(working?.state, .stopped)
    XCTAssertEqual(working?.displayState, .running)
    XCTAssertNil(working?.stopReply)

    let asking = await poll(store, answers, "stopper", .awaitingInput)
    XCTAssertEqual(asking?.displayState, .awaitingInput, "what graphcode status prints")
    XCTAssertEqual(asking.flatMap { AttentionRollup.reason(for: $0) }, .awaitingInput)
    let nodes = await store.graph.nodes
    XCTAssertEqual(AttentionRollup.fullRollup(across: [graph(Array(nodes))]).map(\.nodeID), [id])
  }

  func testTheSettledLatchSurvivesADaemonRestart() async throws {
    let answers = Answers()
    let (first, _) = await stoppedAndSettled(answers)
    let restarted = try await makeStore(reloaded(first.graph), answers: answers)

    // Quiet readings from the stop reply's tail stay masked...
    assertQuietlyStopped(await poll(restarted, answers, "stopper", .awaitingInput), "after restart")
    assertQuietlyStopped(await poll(restarted, answers, "stopper", .idle), "after restart")
    // ...and the next busy turn is a human, on the restarted daemon too.
    _ = await poll(restarted, answers, "stopper", .busy)
    let asking = await poll(restarted, answers, "stopper", .awaitingInput)
    XCTAssertEqual(asking?.displayState, .awaitingInput)
    XCTAssertEqual(asking.flatMap { AttentionRollup.reason(for: $0) }, .awaitingInput)
  }

  func testARestartMidReplyStillMasksTheRestOfTheReply() async throws {
    let answers = Answers()
    let store = await makeStore(
      graph([LoopNode(title: "stopper", loopType: .turnBased, state: .running)]),
      answers: answers)
    await store.handle(.stopNode(store.graph.nodes[0].id))
    assertQuietlyStopped(await poll(store, answers, "stopper", .busy), "mid-reply")
    let replying = await store.graph.nodes[0].stopReply?.phase
    XCTAssertEqual(replying, .replying)

    let restarted = try await self.makeStore(reloaded(store.graph), answers: answers)
    assertQuietlyStopped(
      await poll(restarted, answers, "stopper", .awaitingInput), "reply ends after the restart")
    let after = await restarted.graph.nodes[0].stopReply?.phase
    XCTAssertEqual(after, .settled)
  }

  func testAReplyThatNeverShowedBusySettlesOnceTheGraceHasPassed() async throws {
    let answers = Answers()
    var stopped = LoopNode(title: "stopper", loopType: .turnBased, state: .stopped)
    stopped.stopReply = StopReply(requestedAt: Date())
    let fresh = await makeStore(graph([stopped]), answers: answers)
    // Inside the grace a quiet reading is only the agent not having started yet.
    assertQuietlyStopped(await poll(fresh, answers, "stopper", .awaitingInput), "inside the grace")
    let stillWaiting = await fresh.graph.nodes[0].stopReply?.phase
    XCTAssertEqual(stillWaiting, .awaitingReply)

    stopped.stopReply = StopReply(
      requestedAt: Date().addingTimeInterval(-GraphStore.stopReplyGrace - 1))
    let late = await makeStore(graph([stopped]), answers: answers)
    assertQuietlyStopped(await poll(late, answers, "stopper", .awaitingInput), "past the grace")
    let settled = await late.graph.nodes[0].stopReply?.phase
    XCTAssertEqual(settled, .settled)
    let asking = await poll(late, answers, "stopper", .busy)
    XCTAssertEqual(asking?.displayState, .running)
  }

  /// The host reboots: the stopped loop's session is gone, the restore brings its
  /// conversation back quiet, and only a human typing into it is a new turn.
  func testARestoredSessionIsMaskedUntilItsFirstBusyTurn() async {
    let answers = Answers()
    var stopped = LoopNode(
      title: "poller", loopType: .timeBased, triggerPrompt: "/loop 1h check", state: .stopped)
    stopped.stopReply = StopReply(requestedAt: Date(), phase: .settled)
    let restored = LockedList()
    let store = GraphStore(
      graph: graph([stopped]),
      onRestoreRebootedSessions: { nodes, _ in restored.append(nodes.map(\.title)) },
      onReadPresence: { node, _ in await answers.read(node) })
    let sink = Sink()
    await store.addConnection(id: sink.id, connection: sink, mode: .v2(version: 2))

    assertQuietlyStopped(await poll(store, answers, "poller", .absent), "session gone")
    // A finished loop is not read again once its session is absent, until the restore
    // reopens the window.
    await store.ensureUnattendedSessionsAlive()
    let afterRestore = await store.graph.nodes[0]
    XCTAssertEqual(afterRestore.state, .stopped)
    XCTAssertEqual(afterRestore.stopReply?.phase, .settled)

    assertQuietlyStopped(await poll(store, answers, "poller", .idle), "restored quiet")
    assertQuietlyStopped(await poll(store, answers, "poller", .awaitingInput), "restored, waiting")

    let working = await poll(store, answers, "poller", .busy)
    XCTAssertEqual(working?.displayState, .running)
    let asking = await poll(store, answers, "poller", .awaitingInput)
    XCTAssertEqual(asking?.displayState, .awaitingInput)
    XCTAssertEqual(asking.flatMap { AttentionRollup.reason(for: $0) }, .awaitingInput)
  }
  func testAStopThatCouldNotAskHasNothingToMask() async {
    let answers = Answers()
    let store = await makeStore(
      graph([LoopNode(title: "stopper", loopType: .turnBased, state: .running)]),
      answers: answers, delivers: false)
    await store.handle(.stopNode(store.graph.nodes[0].id))
    let stopped = await store.graph.nodes[0]
    XCTAssertEqual(stopped.state, .stopped)
    XCTAssertNil(stopped.stopReply)
  }

  func testALoopThatLeftStoppedFollowsPresenceAgain() async {
    let answers = Answers()
    var node = LoopNode(title: "stopper", loopType: .turnBased, state: .running)
    node.stopReply = StopReply(requestedAt: Date(), phase: .settled)
    let store = await makeStore(graph([node]), answers: answers)

    let asking = await poll(store, answers, "stopper", .awaitingInput)

    XCTAssertEqual(asking?.displayState, .awaitingInput)
    XCTAssertNil(asking?.stopReply)
  }

  /// The mask above is only honest if nothing re-engages a stopped loop silently. A daemon
  /// restart used to launch a fresh session for a stopped time-based loop while leaving it
  /// `.stopped`, running its trigger prompt under a row that reads stopped.
  func testDaemonStartDoesNotRelaunchAStoppedUnattendedLoop() async {
    let stoppedPoller = LoopNode(
      title: "stopped poller", loopType: .timeBased, triggerPrompt: "/loop 1h check",
      state: .stopped)
    let stoppedGoal = LoopNode(
      title: "stopped goal", loopType: .goalBased, goal: GoalSpec(summary: "ship"),
      state: .stopped)
    let control = LoopNode(
      title: "control", loopType: .timeBased, triggerPrompt: "/loop 1h check", state: .running)
    let ensured = LockedList()
    let store = GraphStore(
      graph: graph([stoppedPoller, stoppedGoal, control]),
      onEnsureSession: { node, _ in ensured.append([node.title]) })

    await store.ensureUnattendedSessions()

    XCTAssertEqual(ensured.titles, ["control"])
  }

  private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ titles: [String]) {
      lock.lock()
      defer { lock.unlock() }
      stored.append(contentsOf: titles)
    }
    var titles: [String] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
  }
}
