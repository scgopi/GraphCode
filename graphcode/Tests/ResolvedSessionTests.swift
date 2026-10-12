import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

#if canImport(Darwin)
  import Darwin
#endif

/// A resolved loop's session is ended to free the machine; the loop and its transcript
/// stay, and opening it brings the conversation back (#346).
@Suite
struct ResolvedSessionTests {
  private struct Harness {
    let store: GraphStore
    let id: UUID
    let ended: LockIsolated<[UUID]>
  }

  private func resolved(
    presence: PresenceReading?, clients: Int? = 0, grace: Duration? = nil
  ) async -> Harness {
    let ended = LockIsolated<[UUID]>([])
    let readPresence: (@Sendable (LoopNode, String?) async -> PresenceReading)? =
      presence.map { reading in { _, _ in reading } }
    let store = GraphStore(
      onReadPresence: readPresence,
      onEndSession: { node, _ in
        ended.withValue { $0.append(node.id) }
        return true
      },
      onAttachedClients: { _, _ in clients },
      onResolvedSessionGrace: { grace })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))
    return Harness(store: store, id: id, ended: ended)
  }

  private let idle = PresenceReading(presence: .idle, confidence: .reported)

  private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<300 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func aQuietSessionIsEndedOnlyWhenItIsStillQuietTheSecondTime() async {
    let harness = await resolved(presence: idle)

    await harness.store.endResolvedSession(harness.id)
    #expect(harness.ended.value.isEmpty)

    await harness.store.endResolvedSession(harness.id)
    #expect(harness.ended.value == [harness.id])
    #expect(await harness.store.graph.nodes[id: harness.id]?.state == .succeeded)
  }

  @Test
  func theScheduledEndActuallyRuns() async {
    let harness = await resolved(presence: idle, grace: .milliseconds(10))

    #expect(await eventually { harness.ended.value == [harness.id] })
  }

  @Test
  func aSessionThatIsBusyUnknownGuessedOrAttachedIsLeftAlone() async {
    let readings: [(PresenceReading?, Int?)] = [
      (PresenceReading(presence: .busy, confidence: .reported), 0),
      (PresenceReading(presence: .awaitingInput, confidence: .reported), 0),
      (.unknown, 0),
      (PresenceReading(presence: .idle, confidence: .heuristic), 0),
      (idle, 1),
      (idle, nil),
      (nil, 0),
    ]
    for (presence, clients) in readings {
      let harness = await resolved(presence: presence, clients: clients)
      await harness.store.endResolvedSession(harness.id)
      await harness.store.endResolvedSession(harness.id)
      #expect(harness.ended.value.isEmpty)
    }
  }

  @Test
  func anUnresolvedLoopsSessionIsNeverEnded() async {
    let ended = LockIsolated<[UUID]>([])
    let store = GraphStore(
      onReadPresence: { _, _ in PresenceReading(presence: .idle, confidence: .reported) },
      onEndSession: { node, _ in
        ended.withValue { $0.append(node.id) }
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id

    await store.endResolvedSession(id)
    await store.endResolvedSession(id)

    #expect(ended.value.isEmpty)
  }

  @Test
  func openingAResolvedLoopWithNoSessionResumesItWithoutTheMetGoal() async {
    let resumed = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { node, _ in
        resumed.withValue { $0.append(node) }
        return true
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id

    await store.handle(.resumeSession(id))
    #expect(resumed.value.isEmpty)

    await store.handle(.completeNode(id, result: nil, from: id))
    await store.handle(.resumeSession(id))

    #expect(resumed.value.map(\.id) == [id])
    #expect(resumed.value.first?.sessionPrompt?.contains("Write it") == false)
    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
  }

  @Test
  func aNewGoalReopensAResolvedLoopWithoutRefiringItsEdges() async {
    let resumed = LockIsolated<[LoopNode]>([])
    let store = GraphStore(
      onSessionAlive: { _, _ in false },
      onResumeSession: { node, _ in
        resumed.withValue { $0.append(node) }
        return false
      })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    await store.handle(
      .createNode(
        NodeDraft(
          title: "Ship", loopType: .turnBased, checkDescription: "?", firstInstruction: "Work")))
    let nodes = await store.graph.nodes
    await store.handle(.createEdge(from: nodes[0].id, to: nodes[1].id, spec: EdgeSpec()))
    await store.handle(.completeNode(nodes[0].id, result: nil, from: nodes[0].id))

    await store.handle(.updateNode(nodes[0].id, update: NodeUpdate(goalSummary: "Add examples")))

    let graph = await store.graph
    let reopened = graph.nodes[id: nodes[0].id]
    #expect(reopened?.state == .running)
    #expect(reopened?.resolution == nil)
    #expect(reopened?.goal?.summary == "Add examples")
    #expect(reopened?.goalSetAt != nil)
    #expect(
      await eventually { resumed.value.first?.sessionPrompt?.contains("Add examples") == true })
    #expect(graph.edges[0].fireCount == 1)
  }

  @Test
  func aResolvedLoopCannotHandItselfANewGoal() async {
    let errors = LockIsolated<[String]>([])
    let store = GraphStore(onAnnounceError: { message in errors.withValue { $0.append(message) } })
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.handle(
      .updateNode(id, update: NodeUpdate(goalSummary: "Do more", updatedBy: id)))

    #expect(await store.graph.nodes[id: id]?.state == .succeeded)
    #expect(errors.value.contains { $0.contains("may not hand itself a new goal") })
  }

  private func reading(_ state: LoopState, _ presence: Presence?) -> LoopNode {
    LoopNode(
      title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"),
      presence: presence.map { PresenceReading(presence: $0, confidence: .reported) },
      state: state)
  }

  @Test
  func aFinishedGoalLoopAnsweringAFollowUpShowsRunningUntilTheTurnEnds() {
    for state in [LoopState.succeeded, .failed] {
      #expect(reading(state, .busy).displayState == .running)
      #expect(reading(state, .awaitingInput).displayState == .awaitingInput)
      #expect(reading(state, .idle).displayState == state)
      #expect(reading(state, .absent).displayState == state)
      #expect(reading(state, nil).displayState == state)
      #expect(reading(state, .busy).isResolved)
    }
    for state in [LoopState.stalled, .stopped] {
      #expect(reading(state, .busy).displayState == .running)
      #expect(reading(state, .idle).displayState == state)
    }
    var exited = reading(.succeeded, .busy)
    exited.presence?.exitCode = 0
    #expect(exited.displayState == .succeeded)
  }

  @Test
  func aFollowUpToAFinishedLoopShowsRunningUntilItsSessionGoesQuietOrAway() async throws {
    let answer = LockIsolated(Presence.busy)
    let reads = LockIsolated(0)
    let store = GraphStore(
      onReadPresence: { _, _ in
        reads.withValue { $0 += 1 }
        return PresenceReading(presence: answer.value, confidence: .reported)
      },
      onSessionAlive: { _, _ in true },
      onResumeSession: { _, _ in true })
    var pair: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer {
      OutboundChannels.close(pair[0])
      close(pair[1])
    }
    await store.addConnection(id: UUID(), fileDescriptor: pair[0])
    await store.handle(
      .createNode(
        NodeDraft(title: "Docs", loopType: .goalBased, goal: GoalSpec(summary: "Write it"))))
    let id = await store.graph.nodes[0].id
    await store.handle(.completeNode(id, result: nil, from: id))

    await store.pollPresence()
    var node = try #require(await store.graph.nodes[id: id])
    #expect(node.state == .succeeded)
    #expect(node.displayState == .running)

    answer.withValue { $0 = .idle }
    await store.pollPresence()
    #expect(await store.graph.nodes[id: id]?.displayState == .succeeded)

    answer.withValue { $0 = .absent }
    await store.pollPresence()
    let readsOnceGone = reads.value
    await store.pollPresence()
    #expect(reads.value == readsOnceGone)

    await store.handle(.resumeSession(id))
    let readsBeforeResume = reads.value
    await store.pollPresence()
    await store.pollPresence()
    #expect(reads.value == readsBeforeResume + 2)
    answer.withValue { $0 = .busy }
    await store.pollPresence()
    node = try #require(await store.graph.nodes[id: id])
    #expect(node.displayState == .running)
    #expect(node.state == .succeeded)
  }

  @Test
  func neverIsStoredAsZeroAndSurvivesARoundTrip() throws {
    var settings = GraphcodeSettings()
    #expect(settings.resolvedSessionGrace == .seconds(600))
    settings.endsResolvedSessionsAfterMinutes = 0
    let decoded = try JSONDecoder().decode(
      GraphcodeSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded.endsResolvedSessionsAfterMinutes == 0)
    #expect(decoded.resolvedSessionGrace == nil)
  }
}
