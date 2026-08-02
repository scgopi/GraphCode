import Foundation
import Testing

@testable import GraphcodeKit

/// The presence poll, and specifically the three guards that decide what it costs.
///
/// Every one of them exists because the naive version — refresh every node every tick and
/// broadcast — spends subprocesses nobody asked for and writes the graph to disk every
/// fifteen seconds, forever, for a field that is deliberately never read back off disk.
@Suite
struct PresencePollingTests {
  private func node(_ title: String, _ state: LoopState) -> LoopNode {
    LoopNode(
      title: title, loopType: .goalBased, goal: GoalSpec(summary: "done"), state: state)
  }

  private func graph(_ nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(scope: LoopGraphScope(projectPath: "/tmp/p", name: "p"))
    for node in nodes { graph.nodes.append(node) }
    return graph
  }

  /// A descriptor the store can actually write to. `addConnection` broadcasts
  /// immediately, and a failed write makes it drop the connection on the spot — so a
  /// placeholder `-1` would silently leave the store with no clients and every
  /// cost assertion below would pass for the wrong reason.
  private func attach(to store: GraphStore) async -> Int32 {
    let descriptor = open("/dev/null", O_WRONLY)
    await store.addConnection(id: UUID(), fileDescriptor: descriptor)
    return descriptor
  }

  /// Counts how many nodes were asked, so "what does a tick cost" is a number.
  private actor Probe {
    private(set) var asked: [String] = []
    private var answers: [String: Presence] = [:]

    func answer(_ title: String, with presence: Presence) { answers[title] = presence }

    func read(_ node: LoopNode) -> PresenceReading {
      asked.append(node.title)
      return PresenceReading(
        presence: answers[node.title] ?? .idle, confidence: .reported)
    }

    func reset() { asked = [] }
  }

  @Test
  func nobodyWatchingCostsNothing() async {
    // The daemon keeps loops running with the app closed. It just stops asking them how
    // they are doing, because there is no surface to show the answer on.
    let probe = Probe()
    let store = GraphStore(
      graph: graph([node("A", .running), node("B", .running)]),
      onReadPresence: { await probe.read($0) })

    await store.pollPresence()

    #expect(await probe.asked.isEmpty)
  }

  @Test
  func aFinishedLoopIsNeverAsked() async {
    // Resolved loops are over by definition: nothing about a session can change what the
    // graph believes, so probing one is a subprocess spent on an answer nobody reads.
    let probe = Probe()
    let store = GraphStore(
      graph: graph([
        node("running", .running), node("succeeded", .succeeded),
        node("failed", .failed), node("stopped", .stopped), node("stalled", .stalled),
        node("blocked", .blocked),
      ]),
      onReadPresence: { await probe.read($0) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(Set(await probe.asked) == ["running", "blocked"])
  }

  @Test
  func oneSubprocessPerUnresolvedLoopPerTick() async {
    // The cost model, stated as a test: per loop, not per app and not per project. `zmx`
    // offers no way to batch it — `list --where k=v` is in its help but ignores the
    // filter, so there is no one-shot read of every session's labels.
    let probe = Probe()
    let store = GraphStore(
      graph: graph((1...5).map { node("n\($0)", .running) }),
      onReadPresence: { await probe.read($0) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await probe.asked.count == 5)
  }

  @Test
  func aTickThatChangesNothingTellsNobody() async {
    // Otherwise every client is handed a whole graph every fifteen seconds to diff, and
    // every tick rewrites graph.json, to say precisely nothing.
    let probe = Probe()
    await probe.answer("A", with: .busy)
    let store = GraphStore(
      graph: graph([node("A", .running)]),
      onGraphChanged: { _ in Issue.record("the poll must not persist the graph") },
      onReadPresence: { await probe.read($0) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()  // first reading: busy
    await probe.reset()
    await store.pollPresence()  // same reading again

    // Still asked — that is the only way to know it hasn't changed — but nothing was
    // persisted, which `onGraphChanged` above would have caught either time.
    #expect(await probe.asked.count == 1)
  }

  @Test
  func theReadingItselfIsCorrectlyPickedUp() async {
    let probe = Probe()
    await probe.answer("A", with: .idle)
    let store = GraphStore(
      graph: graph([node("A", .running)]),
      onReadPresence: { await probe.read($0) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    let updated = await store.graph.nodes.first
    #expect(updated?.presence?.presence == .idle)
    // The whole point: the graph still says running, the card no longer does.
    #expect(updated?.state == .running)
    #expect(updated?.displayState == .idle)
  }

  @Test
  func theIntervalIsSlowEnoughToBeBackgroundNoise() {
    // Fifteen seconds is the lag a human sees between a loop finishing and its card
    // saying so. Worth pinning: dropping it to a second would multiply the subprocess
    // count by fifteen for a difference nobody could perceive on a canvas.
    #expect(ProjectRegistry.presencePollInterval == .seconds(15))
  }
}
