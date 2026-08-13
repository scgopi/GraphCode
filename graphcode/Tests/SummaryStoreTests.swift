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
      id: "p\(pass)-\(seconds)", at: Date(timeIntervalSince1970: Double(seconds)), pass: pass,
      kind: .reading, text: text)
  }

  @Test
  func aPassBoundaryCollapsesItsBeatsToOneLineAndDropsTheRest() {
    let reading = SummaryBeatBuilder.reading(from: [
      beat(1, "Read the probe", at: 1),
      beat(1, "Traced totalTokens", at: 2),
      beat(1, "Trimmed the system preamble", at: 3),
      beat(2, "Working out why cached tokens double-count", at: 4),
    ])

    #expect(reading.finishedPasses.map(\.text) == ["Trimmed the system preamble"])
    #expect(reading.beats.map(\.text) == ["Working out why cached tokens double-count"])

    var summary = LoopSummary()
    summary.merge(reading)
    #expect(summary.passes.map(\.pass) == [1])
    #expect(summary.beats.count == 1)
  }

  /// The bounding claim the whole design rests on: a six-hour loop and a six-minute one
  /// are the same height.
  @Test
  func theStoreStaysBoundedAcrossAFiveHundredBeatRun() {
    var summary = LoopSummary()
    var beats: [SummaryBeat] = []
    for index in 0..<500 {
      beats.append(beat(index / 5 + 1, "beat \(index)", at: index))
      // Merge each poll's view of the tail, the way `GraphStore.refreshSummary` does.
      summary.merge(SummaryBeatBuilder.reading(from: Array(beats.suffix(40))))
      #expect(summary.beats.count <= LoopSummary.maxBeats)
      #expect(summary.passes.count <= LoopSummary.maxPassSummaries)
    }
    #expect(summary.earlierPasses > 90)
    // Everything ever seen is still accounted for, as a number rather than as rows.
    #expect(summary.earlierPasses + summary.passes.count == 99)
  }

  /// A reader whose tail window has moved past a pass must not be able to rewrite what the
  /// store already recorded for it.
  @Test
  func aPassRollsUpOnceAndIsNeverRewritten() {
    var summary = LoopSummary()
    summary.merge(
      SummaryBeatBuilder.reading(from: [beat(1, "First answer", at: 1), beat(2, "now", at: 2)]))
    summary.merge(
      SummaryBeatBuilder.reading(from: [beat(1, "Rewritten answer", at: 1), beat(2, "now", at: 2)]))

    #expect(summary.passes.map(\.text) == ["First answer"])
  }

  @Test
  func unseenCountsAgainstTheWindowsOwnWatermark() {
    var summary = LoopSummary()
    summary.merge(
      SummaryBeatBuilder.reading(from: [
        beat(1, "one", at: 1), beat(1, "two", at: 2), beat(1, "three", at: 3),
      ]))

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

  @Test
  func aSummaryOnANodeSurvivesASaveAndReload() throws {
    var node = LoopNode(title: "Usage")
    node.summary = LoopSummary(
      beats: [beat(7, "Working out why cached tokens double-count", at: 1)],
      passes: [PassSummary(pass: 6, text: "Trimmed the system preamble", delta: "1.4k → 1.3k")],
      earlierPasses: 5)

    let data = try JSONEncoder().encode(node)
    let decoded = try JSONDecoder().decode(LoopNode.self, from: data)

    #expect(decoded.summary?.current?.text == "Working out why cached tokens double-count")
    #expect(decoded.summary?.passes.first?.delta == "1.4k → 1.3k")
    #expect(decoded.summary?.earlierPasses == 5)
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
