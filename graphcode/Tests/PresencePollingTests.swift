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
      onReadPresence: { node, _ in await probe.read(node) })

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
      onReadPresence: { node, _ in await probe.read(node) })
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
      onReadPresence: { node, _ in await probe.read(node) })
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
      onReadPresence: { node, _ in await probe.read(node) })
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
      onReadPresence: { node, _ in await probe.read(node) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    let updated = await store.graph.nodes.first
    #expect(updated?.presence?.presence == .idle)
    // The whole point: the graph still says running, the card no longer does.
    #expect(updated?.state == .running)
    #expect(updated?.displayState == .idle)
  }

  // MARK: - The line under the pill

  /// Answers "what is it doing", and counts who was asked — the second half of the cost
  /// model, since this reading rides the same tick as presence.
  private actor ActivityProbe {
    private(set) var asked: [String] = []
    private var answer = "editing GraphStore.swift"

    func setAnswer(_ text: String) { answer = text }

    func read(_ node: LoopNode) -> String? {
      asked.append(node.title)
      return answer
    }
  }

  @Test
  func aWorkingLoopIsAskedWhatItIsWorkingOn() async {
    // The poll used to refresh presence alone, so a card's live line only ever moved when
    // a human pressed refresh — every loop said RUNNING over the sentence it was created
    // with, however long ago that was.
    let presence = Probe()
    await presence.answer("A", with: .busy)
    let activity = ActivityProbe()
    let store = GraphStore(
      graph: graph([node("A", .running)]),
      onReadActivity: { node, _ in await activity.read(node) },
      onReadPresence: { node, _ in await presence.read(node) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await activity.asked == ["A"])
    #expect(await store.graph.nodes.first?.activity == "editing GraphStore.swift")
  }

  @Test
  func aQuietLoopIsNotAskedAndStopsClaimingToBeMidEdit() async {
    // A loop that has answered is not editing anything, whatever its label still holds.
    // Clearing without a probe is both the honest answer and the cheap one — on a remote
    // project each of these is an ssh round trip.
    let presence = Probe()
    await presence.answer("busy", with: .busy)
    await presence.answer("quiet", with: .idle)
    let activity = ActivityProbe()
    var stale = node("quiet", .running)
    stale.activity = "editing GraphStore.swift"
    let store = GraphStore(
      graph: graph([node("busy", .running), stale, node("done", .succeeded)]),
      onReadActivity: { node, _ in await activity.read(node) },
      onReadPresence: { node, _ in await presence.read(node) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()

    #expect(await activity.asked == ["busy"])
    #expect(await store.graph.nodes[id: stale.id]?.activity == nil)
  }

  @Test
  func aChangedActivityAloneIsWorthTellingSomeoneAbout() async {
    // Presence settles at busy and stays there while the work moves from file to file.
    // Keying the notify off presence alone would freeze the line at the first reading.
    let presence = Probe()
    await presence.answer("A", with: .busy)
    let activity = ActivityProbe()
    let store = GraphStore(
      graph: graph([node("A", .running)]),
      onReadActivity: { node, _ in await activity.read(node) },
      onReadPresence: { node, _ in await presence.read(node) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    await activity.setAnswer("running make check")
    await store.pollPresence()

    #expect(await store.graph.nodes.first?.activity == "running make check")
  }

  // MARK: - The rail's own reading

  /// Switching the summary producer off has to empty the nodes it filled.
  ///
  /// The reader answers `nil` for a transcript that has not moved and an *empty* reading
  /// when it will not be narrating at all, and only the second clears. Without the split,
  /// turning the experiment off left a beat frozen on every card — outranking the live
  /// activity line it had been standing in for — until each loop was deleted.
  @Test
  func turningTheProducerOffEmptiesEveryNodeItFilled() async {
    let presence = Probe()
    await presence.answer("A", with: .busy)
    let beat = SummaryBeat(
      id: "b-1", at: Date(timeIntervalSince1970: 1), pass: 1, kind: .reading,
      text: "Reading the probe")
    let readings = ReadingProbe(
      SummaryReading(beats: [beat], turns: [Date(timeIntervalSince1970: 0)]))
    let store = GraphStore(
      graph: graph([node("A", .running), node("done", .succeeded)]),
      onReadSummary: { _, _ in await readings.read() },
      onReadPresence: { node, _ in await presence.read(node) })
    let descriptor = await attach(to: store)
    defer { close(descriptor) }

    await store.pollPresence()
    #expect(await store.graph.nodes.first?.summary?.current?.text == "Reading the probe")

    // A poll with nothing new to say leaves it standing — the end of a turn is exactly
    // when a rail is worth reading.
    await readings.setAnswer(nil)
    await store.pollPresence()
    #expect(await store.graph.nodes.first?.summary?.current?.text == "Reading the probe")

    await readings.setAnswer(SummaryReading(beats: []))
    await store.pollPresence()
    #expect(await store.graph.nodes.first?.summary == nil)
  }

  private actor ReadingProbe {
    private var answer: SummaryReading?

    init(_ answer: SummaryReading?) { self.answer = answer }

    func setAnswer(_ reading: SummaryReading?) { answer = reading }

    func read() -> SummaryReading? { answer }
  }

  @Test
  func theIntervalIsSlowEnoughToBeBackgroundNoise() {
    // Fifteen seconds is the lag a human sees between a loop finishing and its card
    // saying so. Worth pinning: dropping it to a second would multiply the subprocess
    // count by fifteen for a difference nobody could perceive on a canvas.
    #expect(ProjectRegistry.presencePollInterval == .seconds(15))
  }
}
