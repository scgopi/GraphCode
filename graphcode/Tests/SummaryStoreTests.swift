import Foundation
import Testing

@testable import GraphcodeKit

/// The bounded per-node store the beats are folded into, the settings that gate the whole
/// feature, and the optional model pass.
///
/// Split from `SummaryRailTests` — which reads transcripts — because these assert what
/// happens to a reading *after* it is taken, and the two have no fixtures in common.
@Suite
struct SummaryStoreTests {

  private func beat(_ pass: Int, _ text: String, at seconds: Int) -> SummaryBeat {
    SummaryBeat(
      id: "b-\(seconds)", at: Date(timeIntervalSince1970: Double(seconds)), pass: pass,
      kind: .reading, text: text)
  }

  private func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }

  @Test
  func aPassBoundaryCollapsesItsBeatsToOneLineAndDropsTheRest() {
    let reading = SummaryBeatBuilder.reading(
      from: [
        beat(1, "Read the probe", at: 1),
        beat(1, "Traced totalTokens", at: 2),
        beat(1, "Trimmed the system preamble", at: 3),
        beat(2, "Working out why cached tokens double-count", at: 5),
      ], turns: [at(0), at(4)])

    #expect(reading.finishedPasses.map(\.text) == ["Trimmed the system preamble"])
    #expect(reading.beats.map(\.text) == ["Working out why cached tokens double-count"])

    var summary = LoopSummary()
    summary.merge(reading)
    #expect(summary.passes.map(\.pass) == [1])
    #expect(summary.beats.count == 1)
    #expect(summary.currentPass == 2)
  }

  /// The bounding claim the whole design rests on: a six-hour loop and a six-minute one
  /// are the same height.
  @Test
  func theStoreStaysBoundedAcrossAFiveHundredBeatRun() {
    var summary = LoopSummary()
    var beats: [SummaryBeat] = []
    var turns: [Date] = []
    for index in 0..<500 {
      if index % 5 == 0 { turns.append(at(index)) }
      beats.append(beat(index / 5 + 1, "beat \(index)", at: index))
      // Merge each poll's view of the tail, the way `GraphStore.refreshSummary` does —
      // window and all, since the window is what slides past the older turns.
      let window = Array(beats.suffix(40))
      summary.merge(
        SummaryBeatBuilder.reading(
          from: window,
          turns: turns.filter { $0 >= window[0].at }))
      #expect(summary.beats.count <= LoopSummary.maxBeats)
      #expect(summary.passes.count <= LoopSummary.maxPassSummaries)
    }
    #expect(summary.currentPass == 100)
    #expect(summary.earlierPasses > 90)
    // Everything ever seen is still accounted for, as a number rather than as rows.
    #expect(summary.earlierPasses + summary.passes.count == 99)
  }

  /// The number `PASS 7` prints has to be the loop's own, not the tail read's.
  ///
  /// Measured, not supposed: a transcript on this machine reaches a hundred megabytes and
  /// the tail read is half of one, so a session on its forty-first turn shows ten of them
  /// — and the count walks *backwards* as the file grows. The store counts a turn once,
  /// when it first sees one newer than the last it counted, and everything a window says
  /// is shifted onto that.
  @Test
  func passNumbersSurviveTheWindowSlidingPastTheTurnThatOpenedThem() {
    var summary = LoopSummary()
    // A window that still reaches the session's start: three turns, three passes.
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "one", at: 1), beat(2, "two", at: 3), beat(3, "three", at: 5)],
        turns: [at(0), at(2), at(4)]))
    #expect(summary.currentPass == 3)

    // The same session later. The window has slid: the first two turns are out of it, so
    // the reader calls the newest pass 2 — and a fourth turn has landed since.
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "three", at: 5), beat(2, "four", at: 7)], turns: [at(4), at(6)]))

    #expect(summary.currentPass == 4)
    #expect(summary.beats.map(\.pass) == [4])
    // And a poll that reads the same window again counts nothing twice.
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "three", at: 5), beat(2, "four", at: 7)], turns: [at(4), at(6)]))
    #expect(summary.currentPass == 4)
  }

  /// The section's only number has to belong to the pass it is printed under.
  ///
  /// Keying the metric series by position — sample *n* to pass *n* — holds for a `/loop`
  /// waking on a timer and breaks the moment a human types twice in one pass: the movement
  /// shown is real, and the pass it is shown under is not the one it happened in. Matching
  /// on when the sample was taken cannot be wrong that way.
  @Test
  func aMetricMovementBelongsToThePassItHappenedIn() {
    let samples = [
      MetricSample(value: 1400, recordedAt: at(1)),
      MetricSample(value: 1300, recordedAt: at(9)),
    ]
    var summary = LoopSummary()
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [
          beat(1, "Read the probe", at: 2),
          beat(2, "Trimmed the preamble", at: 10),
          beat(3, "Working on the next thing", at: 20),
        ],
        turns: [at(0), at(8), at(18)], metricSamples: samples))

    // Pass 1 ends before the second sample: nothing moved inside it yet.
    #expect(summary.passes.first(where: { $0.pass == 1 })?.delta == nil)
    // Pass 2 is the one the metric moved in.
    #expect(summary.passes.first(where: { $0.pass == 2 })?.delta == "1.4k → 1.3k")
  }

  /// A reader whose tail window has moved past a pass must not be able to rewrite what the
  /// store already recorded for it.
  @Test
  func aPassRollsUpOnceAndIsNeverRewritten() {
    var summary = LoopSummary()
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "First answer", at: 1), beat(2, "now", at: 3)], turns: [at(0), at(2)]))
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "Rewritten answer", at: 1), beat(2, "now", at: 3)], turns: [at(0), at(2)]))

    #expect(summary.passes.map(\.text) == ["First answer"])
  }

  @Test
  func unseenCountsAgainstTheWindowsOwnWatermark() {
    var summary = LoopSummary()
    summary.merge(
      SummaryBeatBuilder.reading(
        from: [beat(1, "one", at: 1), beat(1, "two", at: 2), beat(1, "three", at: 3)],
        turns: [at(0)]))

    #expect(summary.unseenCount(since: summary.beats.first?.id) == 2)
    #expect(summary.unseenCount(since: summary.beats.last?.id) == 0)
    // No watermark is a first look, not a section full of unread marks.
    #expect(summary.unseenCount(since: nil) == 0)
    // A watermark naming a beat that has rolled out counts as nothing unseen.
    #expect(summary.unseenCount(since: "p0-0") == 0)
  }

  // MARK: - The setting

  @Test
  func theProducerIsOffUntilSomeoneAsksForIt() throws {
    #expect(GraphcodeSettings().summarisesLoops == false)
    // A settings file written before the rail existed is a machine that never opted in.
    let older = Data(
      """
      {"defaultBackend":"claudeCode","showsActivityStrip":true}
      """.utf8)
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: older)
    #expect(decoded.summarisesLoops == false)
    #expect(decoded.showsActivityStrip == true)
  }

  // MARK: - The optional model pass

  @Test
  func theModelPassIsOffEvenWhenSummariesAreOn() throws {
    #expect(GraphcodeSettings().summaryUsesModel == false)
    // Turning the rail on must not start spending money on a machine whose owner only
    // asked to see what their loops were doing.
    let older = Data(
      """
      {"summarisesLoops":true}
      """.utf8)
    let decoded = try JSONDecoder().decode(GraphcodeSettings.self, from: older)
    #expect(decoded.summarisesLoops == true)
    #expect(decoded.summaryUsesModel == false)
  }

  /// Flags checked against each CLI's own `--help`, not assumed — the rule
  /// `BackendCapabilities.isSpiked` exists for.
  @Test
  func eachBackendIsAskedThroughItsOwnNonInteractiveFlag() {
    #expect(
      SummaryModelWriter.invocation(forBackend: .claudeCode, prompt: "p")
        == ["claude", "-p", "p", "--model", "haiku"])
    #expect(
      SummaryModelWriter.invocation(forBackend: .copilotCLI, prompt: "p")
        == ["copilot", "-p", "p", "--model", "haiku"])
    // Codex spells the same flag `-m`, and its non-interactive mode is a subcommand.
    #expect(
      SummaryModelWriter.invocation(forBackend: .codex, prompt: "p")
        == ["codex", "exec", "p", "-m", "haiku"])
    // The standard tier passes no model flag at all, as everywhere else in the app.
    #expect(
      SummaryModelWriter.invocation(forBackend: .claudeCode, prompt: "p", tier: .standard)
        == ["claude", "-p", "p"])
  }

  @Test
  func theBeatCarriesTheFactsAndTheInstructionRefusesInvention() {
    let prompt = SummaryModelWriter.prompt(
      beat: SummaryBeat(
        id: "p7-1", at: Date(), pass: 7, kind: .reading,
        text: "Tracing totalTokens through the probe",
        evidence: "UsageProbe.swift · 3 files read"))

    #expect(prompt.contains("Tracing totalTokens through the probe"))
    #expect(prompt.contains("UsageProbe.swift · 3 files read"))
    #expect(prompt.contains("Invent nothing"))
    // One sentence and one line of evidence — never the transcript.
    #expect(prompt.count < 800)
  }

  @Test
  func onlyOneShortLineIsAcceptedBackFromAModel() {
    #expect(
      SummaryModelWriter.accepted("Tracing totalTokens through the probe")
        == "Tracing totalTokens through the probe")
    // Print mode still prints banners; the answer is the last line.
    #expect(
      SummaryModelWriter.accepted("warning: no config\nFound the double count")
        == "Found the double count")
    #expect(SummaryModelWriter.accepted("\"Found the double count\"") == "Found the double count")
    // Anything that isn't one short line is refused, so the derived beat stands.
    #expect(SummaryModelWriter.accepted("```swift\nlet x = 1\n```") == nil)
    #expect(
      SummaryModelWriter.accepted(
        "Here is a summary of everything the agent has been doing across this pass and "
          + "the previous one as well") == nil)
    #expect(SummaryModelWriter.accepted("   \n  ") == nil)
  }

  @Test
  func nothingIsSentWhenTheHumanHasNotAskedForIt() async {
    var node = LoopNode(title: "Usage")
    let reading = SummaryBeatBuilder.reading(from: [beat(1, "Reading the probe", at: 1)])

    // Producer on, model off: the reading comes back untouched rather than shelling out.
    let unchanged = await SummaryModelWriter.applied(
      to: reading, node: node, projectPath: nil,
      settings: GraphcodeSettings(summarisesLoops: true, summaryUsesModel: false))
    #expect(unchanged == reading)

    // Model on, but this beat is already the one on the node — nothing has changed, so
    // there is nothing to pay for.
    node.summary = LoopSummary(beats: reading.beats)
    let deduped = await SummaryModelWriter.applied(
      to: reading, node: node, projectPath: nil,
      settings: GraphcodeSettings(summarisesLoops: true, summaryUsesModel: true))
    #expect(deduped == reading)
  }

  /// A quiet loop must cost a `stat` and no read, or dropping the `busy` guard would put
  /// a tail parse per idle loop on every poll.
  @Test
  func aTranscriptIsOnlyReReadAfterItHasBeenWritten() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("freshness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("session.jsonl")
    try "one\n".write(to: url, atomically: true, encoding: .utf8)
    let node = UUID()

    // First sight of a file is always a read.
    #expect(await TranscriptFreshness.shared.hasChanged(url, forNode: node) == true)
    #expect(await TranscriptFreshness.shared.hasChanged(url, forNode: node) == false)

    // A write moves it, and only the node that has already looked is spared.
    try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(await TranscriptFreshness.shared.hasChanged(url, forNode: node) == true)
    #expect(await TranscriptFreshness.shared.hasChanged(url, forNode: UUID()) == true)

    // A file that cannot be read at all is read rather than assumed unchanged: freezing
    // the rail silently is the worse failure.
    #expect(
      await TranscriptFreshness.shared.hasChanged(
        root.appendingPathComponent("missing.jsonl"), forNode: node) == true)
  }

  @Test
  func aSummaryOnANodeSurvivesASaveAndReload() throws {
    var node = LoopNode(title: "Usage")
    node.summary = LoopSummary(
      beats: [beat(7, "Working out why cached tokens double-count", at: 1)],
      passes: [PassSummary(pass: 6, text: "Trimmed the system preamble", delta: "1.4k → 1.3k")],
      currentPass: 7, lastTurnAt: at(1))

    let data = try JSONEncoder().encode(node)
    let decoded = try JSONDecoder().decode(LoopNode.self, from: data)

    #expect(decoded.summary?.current?.text == "Working out why cached tokens double-count")
    #expect(decoded.summary?.passes.first?.delta == "1.4k → 1.3k")
    // Where the count picks up from after a relaunch — without it every restart would
    // renumber the run from whatever the next tail read happened to reach.
    #expect(decoded.summary?.currentPass == 7)
    #expect(decoded.summary?.lastTurnAt == at(1))
    #expect(decoded.summary?.earlierPasses == 5)
  }

  /// A summary written by a build that numbered passes differently must still load: a
  /// `LoopSummary` that throws takes the whole graph file with it.
  @Test
  func aSummaryFromAnOlderBuildStillLoads() throws {
    let older = Data(
      """
      {"beats":[],"passes":[],"earlierPasses":5}
      """.utf8)
    let decoded = try JSONDecoder().decode(LoopSummary.self, from: older)
    #expect(decoded.currentPass == 0)
    #expect(decoded.earlierPasses == 0)
  }

  /// A graph saved before the field existed must still load — `ProjectPersistence` turns
  /// any decode failure into "no saved graph", which would throw away someone's loops.
  @Test
  func aNodeSavedBeforeSummariesExistedStillLoads() throws {
    let older = Data(
      """
      {"id":"\(UUID().uuidString)","title":"Usage"}
      """.utf8)
    let decoded = try JSONDecoder().decode(LoopNode.self, from: older)
    #expect(decoded.summary == nil)
  }
}
