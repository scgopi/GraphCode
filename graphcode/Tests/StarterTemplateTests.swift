import Foundation
import GraphcodeKit
import Testing

/// The briefs a fresh install starts with, and the once-only seeding that puts them
/// on disk. See `StarterTemplates` for why an empty ⌘T picker is the problem being
/// solved, and what each template is chosen to demonstrate.
@Suite
struct StarterTemplateTests {
  private let home: URL
  private let storage: TemplateStorage

  init() {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("starter-tests-\(UUID().uuidString)", isDirectory: true)
    storage = TemplateStorage(
      homeDirectory: home,
      projectDirectory: { _ in URL(fileURLWithPath: "/nonexistent", isDirectory: true) })
  }

  // MARK: - The set itself

  /// The starter set is a taxonomy lesson before it is a convenience: every loop type
  /// has to be represented, or the type with no example is the one nobody tries.
  @Test
  func everyLoopTypeHasAStarter() {
    let shapes = Set(StarterTemplates.all.map { $0.shape })
    #expect(shapes == [nil, .goalBased, .timeBased, .turnBased, .composite])
  }

  /// Each type's lesson lives in its *settings*, not its prose — this is the table in
  /// `StarterTemplates`' doc comment, asserted.
  @Test
  func eachTypesSettingsTeachThatType() throws {
    // Main asks nothing: no done check, no cadence, nothing to decide.
    for main in StarterTemplates.all where main.shape == nil {
      #expect(main.settings == nil)
    }
    // Goal shows all three of its cases: a check that decides, no check at all, and
    // a metric.
    let goals = StarterTemplates.all.filter { $0.shape == .goalBased }
    let withCheck = goals.filter { $0.settings?.doneCheck != nil }.count
    let withoutCheck = goals.filter { $0.settings?.doneCheck == nil }.count
    let withMetric = goals.filter { $0.settings?.metric != nil }.count
    #expect(withCheck > 0)
    #expect(withoutCheck > 0)
    #expect(withMetric > 0)
    // Timed always carries a cadence — a timed loop without one is not the type.
    for timed in StarterTemplates.all where timed.shape == .timeBased {
      #expect(timed.settings?.cadence?.isEmpty == false)
    }
    // Turn shows both pause rhythms side by side; one of each is the whole lesson.
    let pauses = StarterTemplates.all
      .filter { $0.shape == .turnBased }
      .compactMap { $0.settings?.pausesBeforeWritesOnly }
    #expect(Set(pauses) == [true, false])
  }

  /// The composite carries a real orchestration — children *and* the edges between
  /// them, which is what makes a composite template worth sharing.
  @Test
  func theCompositeStarterCarriesItsChildrenAndEdges() throws {
    let composite = try #require(StarterTemplates.all.first(where: { $0.shape == .composite }))
    let graph = try #require(composite.settings?.carriedGraph)
    #expect(graph.nodes.map(\.title) == ["Reviewer", "Fixer", "Verifier"])
    #expect(graph.edges.count == 2)
    // Wired as a chain, not a fan: the reviewer's findings reach the verifier only by
    // going through the fixer.
    let byID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.title) })
    let wiring = Set(graph.edges.map { "\(byID[$0.from] ?? "?")→\(byID[$0.to] ?? "?")" })
    #expect(wiring == ["Reviewer→Fixer", "Fixer→Verifier"])
  }

  /// Ids are fixed, not freshly minted: a loop following a starter has to keep
  /// following it across a reinstall, and two machines have to agree on which
  /// template a shared file is.
  @Test
  func starterIdsAreStableAcrossCalls() {
    #expect(StarterTemplates.all.map(\.id) == StarterTemplates.all.map(\.id))
    #expect(Set(StarterTemplates.all.map(\.id)).count == StarterTemplates.all.count)
    #expect(Set(StarterTemplates.all.map(\.fileName)).count == StarterTemplates.all.count)
  }

  /// The three offered on an empty canvas climb the commitment ladder — that is what
  /// makes the row a lesson rather than three arbitrary briefs.
  @Test
  func theFirstLaunchPicksSpanTheCommitmentLadder() {
    let picks = StarterTemplates.firstLaunchPicks
    #expect(picks.count == 3)
    #expect(picks.map { $0.shape } == [nil, .goalBased, .timeBased])
    // The team-leading brief is the top of the picker, not of the canvas: the row
    // there is for somebody's first loop, and a coordinator is not that.
    #expect(!picks.contains { $0.id == StarterTemplates.all[0].id })
    // And they are really in the shipped set, not a fourth thing nobody can find again.
    let shipped = StarterTemplates.all.map(\.id)
    for pick in picks {
      #expect(shipped.contains(pick.id))
    }
  }

  /// Every token is a hole somebody can be expected to fill from where they're
  /// standing — and the brief has to say enough for them to know what to put in it.
  @Test
  func everyStarterReadsAsAFinishedBrief() {
    for template in StarterTemplates.all {
      #expect(!template.name.isEmpty)
      #expect(template.body.count > 40, "\(template.name) is too terse to teach anything")
      #expect(template.isStarter)
      #expect(template.origin == .home)
    }
  }

  /// The brief at the top is about the task; the Artifactory appears in it as the
  /// team's inbox, and every command it names is one the CLI actually has.
  @Test
  func theTeamLeadingStarterNamesRealCommands() throws {
    let lead = try #require(StarterTemplates.all.first)
    #expect(lead.name == "Lead a team toward a goal")
    #expect(lead.shape == nil)
    #expect(lead.settings == nil)
    #expect(lead.tokens == ["goal", "topic"])
    for command in [
      "graphcode node create", "--type goal", "--type time", "/loop 30m",
      "graphcode artifactory watch", "graphcode artifactory sync", "graphcode artifactory post",
      "graphcode node send", "--follow-up",
    ] {
      #expect(lead.body.contains(command), "missing \(command)")
    }
    // Task first: the goal is the first thing the brief says.
    #expect(lead.body.hasPrefix("Lead the work toward this goal: {goal}."))
  }

  // MARK: - Seeding

  /// An install that already has beta2's ten still gets a starter shipped later —
  /// the marker records ids, so a new id is owed and an old one never re-arrives.
  @Test
  func aStarterShippedLaterStillArrivesOnAnOlderInstall() throws {
    let original = Array(StarterTemplates.all.dropFirst())  // what beta2 shipped
    try storage.seedStartersIfNeeded(original)
    #expect(storage.load(projectPath: nil).count == original.count)
    // …and one of those was deleted before the update.
    let deleted = try #require(storage.load(projectPath: nil).last)
    try storage.delete(deleted)

    let arrived = try storage.seedStartersIfNeeded(StarterTemplates.all)
    #expect(arrived.map(\.name) == ["Lead a team toward a goal"])
    let names = storage.load(projectPath: nil).map(\.name)
    #expect(names.contains("Lead a team toward a goal"))
    #expect(!names.contains(deleted.name))
  }

  /// beta2 and beta3 wrote an empty marker. That install seeded everything that
  /// existed then, so the empty file has to read as exactly that set — the one
  /// starter added since is what it is still owed, and nothing it deleted returns.
  @Test
  func anEmptyLegacyMarkerMeansTheFirstBatchWasSeeded() throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try Data().write(to: home.appendingPathComponent(TemplateStorage.seededMarker))

    let arrived = try storage.seedStartersIfNeeded()
    #expect(arrived.map(\.name) == ["Lead a team toward a goal"])
    #expect(storage.load(projectPath: nil).count == 1)
  }

  @Test
  func seedingWritesEveryStarterOnce() throws {
    let written = try storage.seedStartersIfNeeded()
    #expect(written.count == StarterTemplates.all.count)
    #expect(storage.load(projectPath: nil).count == StarterTemplates.all.count)

    // Second launch: nothing more to do.
    let second = try storage.seedStartersIfNeeded()
    #expect(second.isEmpty)
  }

  /// A starter you delete stays deleted. Seeding on every launch would make the
  /// library un-curatable, which is worse than shipping nothing.
  @Test
  func aDeletedStarterDoesNotComeBack() throws {
    try storage.seedStartersIfNeeded()
    let victim = try #require(storage.load(projectPath: nil).first)
    try storage.delete(victim)

    try storage.seedStartersIfNeeded()
    let remaining = storage.load(projectPath: nil).map(\.id)
    #expect(!remaining.contains(victim.id))
  }

  /// A file already at that name belongs to whoever wrote it, first run or not.
  @Test
  func seedingNeverOverwritesSomeoneElsesFile() throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let occupied = home.appendingPathComponent(StarterTemplates.all[0].fileName)
    try "Mine, not the app's.".write(to: occupied, atomically: true, encoding: .utf8)

    try storage.seedStartersIfNeeded()
    let kept = try String(contentsOf: occupied, encoding: .utf8)
    #expect(kept == "Mine, not the app's.")
  }

  /// `starter: true` is written into the file and read back, so the mark survives an
  /// edit and is visible to anyone reading the folder.
  @Test
  func theStarterMarkRoundTripsThroughTheFile() throws {
    try storage.seedStartersIfNeeded()
    let loaded = storage.load(projectPath: nil)
    let marked = loaded.filter(\.isStarter).count
    #expect(marked == StarterTemplates.all.count)
    #expect(loaded.count == StarterTemplates.all.count)

    // A template nobody marked is not a starter.
    let (mine, _) = try storage.save(
      PromptTemplate(name: "Mine", body: "My own brief."), to: .home, projectPath: nil)
    #expect(!mine.isStarter)
    let reloaded = storage.load(projectPath: nil).first(where: { $0.id == mine.id })
    #expect(reloaded?.isStarter == false)
  }

  /// The marker is a dotfile, so it is never mistaken for a template.
  @Test
  func theSeedMarkerIsNotOfferedAsATemplate() throws {
    try storage.seedStartersIfNeeded()
    let names = storage.load(projectPath: nil).map(\.name)
    #expect(!names.contains(where: { $0.contains("seeded") }))
  }
}
