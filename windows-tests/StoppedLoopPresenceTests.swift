import Foundation
import XCTest

@testable import GraphcodeKit

/// A stopped loop's session is asked to stop, not killed, so the agent's own reply to the
/// stop prompt arrives as presence readings (busy, then awaitingInput or idle). Those
/// readings must never move a loop the user stopped out of `.stopped`, or into Needs you.
/// Known limit, deliberately not tested as a pass: a human typing into the still-live pane
/// is indistinguishable from that reply by presence alone.
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

  /// The contract is "Stop means off": `.stopped` outranks presence, so nothing the session
  /// says afterwards moves the loop. That is deliberately blunt: it also hides a human
  /// typing into the still-live pane, which only an explicit resume or a turn signal from
  /// the agent could tell apart. So the tests below pin where presence is followed again:
  /// whenever the state leaves `.stopped`.
  func testLeavingStoppedByAMissingCLIRestartFollowsPresenceAgain() async {
    let node = {
      var node = LoopNode(
        title: "poller", loopType: .timeBased, triggerPrompt: "/loop 1h check",
        presence: PresenceReading(presence: .awaitingInput, confidence: .reported),
        state: .stopped)
      node.launchFailure = LaunchFailure(executable: "claude", backend: .claudeCode)
      return node
    }()
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    graph.nodes.append(node)
    let store = GraphStore(graph: graph, onEnsureSession: { _, _ in })
    XCTAssertEqual(node.displayState, .stopped)

    await store.handle(.restartNode(node.id))

    let restarted = await store.graph.nodes[id: node.id]
    XCTAssertEqual(restarted?.state, .running)
    XCTAssertEqual(restarted?.displayState, .awaitingInput)
  }

  func testLeavingStoppedByANewGoalFollowsPresenceAgain() async {
    let answers = Answers()
    let store = GraphStore(
      graph: LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p")),
      onReadPresence: { node, _ in await answers.read(node) })
    let sink = Sink()
    await store.addConnection(id: sink.id, connection: sink, mode: .v2(version: 2))
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.stopNode(id))
    await answers.set("Docs", .awaitingInput)
    await store.pollPresence()
    let stopped = await store.graph.nodes[id: id]
    XCTAssertEqual(stopped?.displayState, .stopped)

    await store.handle(.updateNode(id, update: NodeUpdate(goalSummary: "Add examples")))
    await store.pollPresence()

    let reopened = await store.graph.nodes[id: id]
    XCTAssertEqual(reopened?.state, .running)
    XCTAssertEqual(reopened?.displayState, .awaitingInput)
  }

  /// Nothing may start a session for a node that is still `.stopped`: the contract hides
  /// whatever that session asks. The explicit ways back are a missing-CLI restart and a
  /// new goal; Pilot and Arm of a composite are refused while it is stopped.
  private func stoppedComposite(_ ensured: EnsuredTitles) async -> (GraphStore, UUID) {
    var sub = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "sub"))
    sub.nodes.append(
      LoopNode(
        title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check", state: .running))
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    let composite = LoopNode(
      title: "Comp", loopType: .composite, subGraph: sub, pilotState: .piloted, state: .running)
    graph.nodes.append(composite)
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.append(node.title) },
      onDeliverMessage: { _, _, _ in true })
    await store.handle(.stopNode(composite.id))
    return (store, composite.id)
  }

  func testPilotingOrArmingAStoppedCompositeStartsNothing() async {
    let ensured = EnsuredTitles()
    let (store, id) = await stoppedComposite(ensured)
    let before = await store.graph.nodes[id: id]
    XCTAssertEqual(before?.state, .stopped)
    XCTAssertEqual(before?.subGraph?.nodes.map(\.state), [.stopped])

    await store.handle(.pilotComposite(id))
    await store.handle(.armComposite(id))

    let after = await store.graph.nodes[id: id]
    XCTAssertEqual(after?.state, .stopped)
    XCTAssertEqual(after?.pilotState, .piloted)
    XCTAssertEqual(after?.subGraph?.nodes.map(\.state), [.stopped])
    XCTAssertEqual(ensured.titles, [], "no session may start under a stopped row")
  }

  func testPilotingACompositeDoesNotStartAWorkerThatWasStoppedOnItsOwn() async {
    var sub = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "sub"))
    sub.nodes.append(
      LoopNode(
        title: "Stopped worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
        state: .stopped))
    sub.nodes.append(
      LoopNode(
        title: "Other worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check",
        state: .idle))
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    let composite = LoopNode(title: "Comp", loopType: .composite, subGraph: sub)
    graph.nodes.append(composite)
    let ensured = EnsuredTitles()
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.append(node.title) })

    await store.handle(.pilotComposite(composite.id))

    XCTAssertEqual(ensured.titles, ["Other worker"])
  }

  func testPromotingAStoppedSketchIsRefused() async {
    let ensured = EnsuredTitles()
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    let sketch = LoopNode(title: "Sketch", loopType: .sketch, state: .stopped)
    graph.nodes.append(sketch)
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.append(node.title) })

    await store.handle(
      .promoteNode(sketch.id, promotion: .timed(triggerPrompt: "/loop 1h check"), promotedBy: nil))

    let after = await store.graph.nodes[id: sketch.id]
    XCTAssertEqual(after?.state, .stopped)
    XCTAssertEqual(after?.loopType, .sketch)
    XCTAssertEqual(ensured.titles, [])
  }

  func testSpawningFromAStoppedCompositeTemplateIsAFreshRun() async {
    var sub = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "sub"))
    sub.nodes.append(
      LoopNode(
        title: "Worker", loopType: .timeBased, triggerPrompt: "/loop 1h Check", state: .stopped))
    let template = LoopNode(
      title: "Template", loopType: .composite, subGraph: sub, pilotState: .piloted,
      state: .stopped)
    let trigger = LoopNode(
      title: "Trigger", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "C:\\p", name: "p"))
    graph.nodes.append(contentsOf: [trigger, template])
    graph.edges.append(LoopEdge(from: trigger.id, to: template.id, kind: .spawn))
    let ensured = EnsuredTitles()
    let store = GraphStore(
      graph: graph, onEnsureSession: { node, _ in ensured.append(node.title) })

    await store.handle(.nodeCheckApproved(trigger.id))

    let spawned = await store.graph.nodes.last
    XCTAssertEqual(spawned?.title.hasPrefix("Template"), true)
    // Not a way back for the template's workers: the copy's own are re-identified and
    // reset to idle, so what starts is a new run that follows presence like any other.
    XCTAssertEqual(spawned?.subGraph?.nodes.map(\.state), [.idle])
    XCTAssertEqual(ensured.titles, ["Worker"])
  }

  /// A daemon restart used to launch a fresh session for a stopped time-based loop while
  /// leaving it `.stopped`: that session would run the loop's work, and could ask a
  /// question, under a row that reads stopped.
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
