import Foundation
import XCTest

@testable import GraphcodeKit

/// A stopped loop's session is asked to stop, not killed, so the agent's own reply to the
/// stop prompt arrives as presence readings (busy, then awaitingInput or idle). Those
/// readings must never move a loop the user stopped out of `.stopped`.
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

  func testStoppedLoopStaysStoppedAndOutOfNeedsYouWhileItsAgentAnswersTheStopPrompt() async {
    let answers = Answers()
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    graph.nodes.append(
      LoopNode(title: "stopper", loopType: .turnBased, state: .running))
    graph.nodes.append(
      LoopNode(title: "sibling", loopType: .turnBased, state: .running))
    let store = GraphStore(
      graph: graph, onReadPresence: { node, _ in await answers.read(node) })
    let sink = Sink()
    await store.addConnection(id: sink.id, connection: sink, mode: .v2(version: 2))
    let stopperID = await store.graph.nodes[0].id

    await store.handle(.stopNode(stopperID))
    for answer in [Presence.busy, .awaitingInput, .idle] {
      await answers.set("stopper", answer)
      await answers.set("sibling", .awaitingInput)
      await store.pollPresence()

      let stopped = await store.graph.nodes[id: stopperID]
      XCTAssertEqual(stopped?.state, .stopped)
      XCTAssertEqual(stopped?.displayState, .stopped, "after reading \(answer)")
      XCTAssertNil(stopped.flatMap { AttentionRollup.reason(for: $0) })
    }

    // Only the stopped loop is exempt: a loop nobody stopped still asks for the human.
    let sibling = await store.graph.nodes[1]
    XCTAssertEqual(sibling.displayState, .awaitingInput)
    XCTAssertEqual(AttentionRollup.reason(for: sibling), .awaitingInput)
  }

  /// The mask above is only honest if nothing re-engages a stopped loop behind its back.
  /// A daemon restart used to launch a fresh session for a stopped time-based loop while
  /// leaving it `.stopped`: that session would work (and could ask a question) under a
  /// row that reads stopped.
  func testDaemonStartDoesNotRelaunchAStoppedUnattendedLoop() async {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    graph.nodes.append(
      LoopNode(
        title: "stopped poller", loopType: .timeBased, triggerPrompt: "/loop 1h check",
        state: .stopped))
    graph.nodes.append(
      LoopNode(
        title: "stopped goal", loopType: .goalBased, goal: GoalSpec(summary: "ship"),
        state: .stopped))
    graph.nodes.append(
      LoopNode(
        title: "control", loopType: .timeBased, triggerPrompt: "/loop 1h check",
        state: .running))
    let ensured = EnsuredTitles()
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.append(node.title) })

    await store.ensureUnattendedSessions()

    XCTAssertEqual(ensured.titles, ["control"])
  }

  private final class EnsuredTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ title: String) {
      lock.lock()
      defer { lock.unlock() }
      stored.append(title)
    }
    var titles: [String] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
  }
}
