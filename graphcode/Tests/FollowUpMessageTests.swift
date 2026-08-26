import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

/// `node send --follow-up`: the sender chooses deference over immediacy. A busy target
/// keeps its turn uninterrupted and hears the message when it next goes idle; the
/// memory log carries it from the moment it was queued, so nothing depends on the
/// queue surviving.
@Suite
struct FollowUpMessageTests {
  private func graph(targetPresence: Presence?, state: LoopState = .running) -> LoopGraph {
    LoopGraph(
      project: ProjectRef(path: "/tmp/followup", name: "followup"),
      nodes: [
        LoopNode(
          title: "Worker", loopType: .goalBased,
          goal: GoalSpec(summary: "work"),
          presence: targetPresence.map { PresenceReading(presence: $0, confidence: .reported) },
          state: state)
      ])
  }

  @Test
  func aFollowUpToABusyLoopWaitsForIdleThenDelivers() async {
    let delivered = LockIsolated<[String]>([])
    let remembered = LockIsolated<[String]>([])
    let presence = LockIsolated(Presence.busy)
    let graph = graph(targetPresence: .busy)
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: presence.value, confidence: .reported) },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "the API changed", from: nil, followUp: true))

    // Not typed in mid-turn — staged to memory, waiting on idle.
    #expect(delivered.value.isEmpty)
    #expect(remembered.value.contains { $0.contains("follow-up staged") })

    // Still busy at the next settle: still waiting.
    await store.handle(.refreshUsage)
    #expect(delivered.value.isEmpty)

    presence.setValue(.idle)
    await store.handle(.refreshUsage)
    #expect(delivered.value == ["[graphcode] the API changed"])

    // Delivered once — the queue entry is spent.
    await store.handle(.refreshUsage)
    #expect(delivered.value.count == 1)
  }

  @Test
  func aFollowUpToAnIdleLoopDeliversImmediately() async {
    let delivered = LockIsolated<[String]>([])
    let graph = graph(targetPresence: .idle)
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      })

    await store.handle(
      .messageNode(graph.nodes[0].id, text: "ready when you are", from: nil, followUp: true))

    #expect(delivered.value == ["[graphcode] ready when you are"])
  }

  @Test
  func aFollowUpToAResolvedLoopIsStagedLikeAnyOtherMessage() async {
    let delivered = LockIsolated<[String]>([])
    let remembered = LockIsolated<[String]>([])
    let graph = graph(targetPresence: nil, state: .succeeded)
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onAppendMemory: { _, entry in remembered.withValue { $0.append(entry) } })

    await store.handle(
      .messageNode(graph.nodes[0].id, text: "for your next wake", from: nil, followUp: true))

    #expect(delivered.value.isEmpty)
    #expect(remembered.value.contains { $0.contains("while you were away") })
  }

  @Test
  func aTargetThatDiesWhileQueuedIsDroppedNotRedelivered() async {
    // The memory log has carried the message since it was staged; a dead session's
    // next wake reads it there, so the queue owes it nothing further.
    let delivered = LockIsolated<[String]>([])
    let graph = graph(targetPresence: .busy)
    let store = GraphStore(
      graph: graph,
      onDeliverMessage: { _, message, _ in
        delivered.withValue { $0.append(message) }
        return true
      },
      onReadPresence: { _, _ in PresenceReading(presence: .busy, confidence: .reported) })
    let nodeID = graph.nodes[0].id

    await store.handle(.messageNode(nodeID, text: "late news", from: nil, followUp: true))
    await store.handle(.nodeCheckRejected(nodeID))
    await store.handle(.refreshUsage)

    #expect(delivered.value.isEmpty)
  }

  @Test
  func anOldMessageNodeFrameStillDecodesAsAnImmediateSend() throws {
    // Clients that predate the flag omit the key entirely; the frame must decode as
    // the immediate send it always was, not fail the connection.
    let json = #"{"messageNode":{"_0":"00000000-0000-0000-0000-000000000001","text":"hi"}}"#
    let command = try JSONDecoder().decode(GraphCommand.self, from: Data(json.utf8))
    guard case .messageNode(_, let text, let from, let followUp) = command else {
      Issue.record("expected messageNode, got \(command)")
      return
    }
    #expect(text == "hi")
    #expect(from == nil)
    #expect(followUp == nil)
  }

  @Test
  func theCLIParsesFollowUpOnlyAsTheFirstWord() throws {
    let flagged = try GraphcodeCommand.parse([
      "node", "send", "/tmp/p", UUID().uuidString, "--follow-up", "tests", "are", "green",
    ])
    guard case .sendMessage(_, _, let text, let followUp) = flagged else {
      Issue.record("expected sendMessage, got \(flagged)")
      return
    }
    #expect(followUp == true)
    #expect(text == "tests are green")

    // Anywhere later it is message text, so the words stay sendable.
    let literal = try GraphcodeCommand.parse([
      "node", "send", "/tmp/p", UUID().uuidString, "pass", "--follow-up", "to", "the", "critic",
    ])
    guard case .sendMessage(_, _, let literalText, let literalFlag) = literal else {
      Issue.record("expected sendMessage, got \(literal)")
      return
    }
    #expect(literalFlag == false)
    #expect(literalText == "pass --follow-up to the critic")
  }
}
