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
    // Goal is the workhorse and gets three. None carries a setting with a hole in
    // it — see `theOneFillRule` — so the three differ by brief, not by settings.
    let goals = StarterTemplates.all.filter { $0.shape == .goalBased }
    #expect(goals.count == 3)
    #expect(Set(goals.map(\.name)).count == 3)
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

  /// The seeder decides whether a file is still the one it wrote by hashing what it
  /// would write; a starter that encoded differently on every access would look
  /// edited-by-us at every launch and be rewritten each time.
  @Test
  func everyStarterEncodesIdentically() {
    let once = StarterTemplates.all.map { TemplateFileCodec.encode($0) }
    let twice = StarterTemplates.all.map { TemplateFileCodec.encode($0) }
    #expect(once == twice)
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

  /// **One fill, at the top.** At most one token per starter, appearing exactly once,
  /// on the first line — and never in a setting. Filling a template is typing over
  /// one thing, not hunting the same word through four paragraphs.
  @Test
  func theOneFillRule() {
    for template in StarterTemplates.all {
      let tokens = template.tokens
      #expect(tokens.count <= 1, "\(template.name) asks for \(tokens)")
      if let token = tokens.first {
        let occurrences = template.body.components(separatedBy: "{\(token)}").count - 1
        #expect(occurrences == 1, "\(template.name) repeats {\(token)} \(occurrences)×")
        let firstLine =
          template.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        #expect(firstLine.contains("{\(token)}"), "\(template.name)'s hole isn't on its first line")
      }
      for setting in [
        template.settings?.doneCheck, template.settings?.metric, template.settings?.branch,
        template.settings?.cadence,
      ] {
        #expect(
          PromptTemplate.tokens(in: setting ?? "").isEmpty,
          "\(template.name) hides a hole in a setting")
      }
      // A carried graph is nowhere the dialog can show a hole, so it must have none.
      for child in template.settings?.carriedGraph?.nodes ?? [] {
        let inSummary = PromptTemplate.tokens(in: child.goal?.summary ?? "")
        let inPredicate = PromptTemplate.tokens(in: child.goal?.predicate ?? "")
        #expect(inSummary.isEmpty, "\(child.title) carries \(inSummary)")
        #expect(inPredicate.isEmpty, "\(child.title) carries \(inPredicate)")
      }
      // Names are names, not fill-in forms.
      #expect(
        PromptTemplate.tokens(in: template.name).isEmpty, "\(template.name) has a hole in its name")
    }
  }

  /// Short enough to read in the picker before choosing it. The leader is the longest
  /// on purpose and still under a hundred words; the rest are a few sentences.
  @Test
  func everyStarterIsShort() {
    for template in StarterTemplates.all {
      let words = template.body.split(whereSeparator: \.isWhitespace).count
      #expect(words <= 100, "\(template.name) is \(words) words")
      #expect(words >= 15, "\(template.name) is too terse to teach anything")
      #expect(template.isStarter)
      #expect(template.origin == .home)
    }
  }

  /// The brief at the top is about the task; the Mailroom appears in it as the
  /// team's inbox, and every command it names is one the CLI actually has.
  @Test
  func theTeamLeadingStarterNamesRealCommands() throws {
    let lead = try #require(StarterTemplates.all.first)
    #expect(lead.name == "Lead a team toward a goal")
    #expect(lead.shape == nil)
    #expect(lead.settings == nil)
    #expect(lead.tokens == ["goal"])
    // Task first: the goal is the first line, and the only thing to fill.
    #expect(lead.body.hasPrefix("Goal: {goal}\n"))
    // The method in words, not a CLI transcript — the loop's own instructions carry
    // the flags. What the brief has to say is which loop type for which piece, and
    // that the Mailroom is the inbox.
    for phrase in ["goal loop", "timed loop", "Mailroom", "inbox", "topic", "closing note"] {
      #expect(lead.body.contains(phrase), "missing \(phrase)")
    }
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

  /// A starter nobody edited is ours to keep current: when the shipped text changes,
  /// the file is refreshed. One somebody edited is theirs, and is left alone.
  @Test
  func untouchedStartersRefreshAndEditedOnesDoNot() throws {
    var first = StarterTemplates.whereDoesThisLive
    first.body = "The old text this install was shipped."
    var second = StarterTemplates.whyDidThisBreak
    second.body = "Another old text."
    try storage.seedStartersIfNeeded([first, second])

    // The person edits the second one.
    let mine = try #require(storage.load(projectPath: nil).first { $0.id == second.id })
    var edited = mine
    edited.body = "My own rewrite."
    try storage.update(edited, replacing: mine)

    // A new build ships new text for both.
    let refreshed = try storage.seedStartersIfNeeded([
      StarterTemplates.whereDoesThisLive, StarterTemplates.whyDidThisBreak,
    ])
    #expect(refreshed.map(\.id) == [first.id])
    let bodies = Dictionary(
      uniqueKeysWithValues: storage.load(projectPath: nil).map { ($0.id, $0.body) })
    #expect(bodies[first.id] == StarterTemplates.whereDoesThisLive.body)
    #expect(bodies[second.id] == "My own rewrite.")
    // And nothing further to do next launch.
    let again = try storage.seedStartersIfNeeded([
      StarterTemplates.whereDoesThisLive, StarterTemplates.whyDidThisBreak,
    ])
    #expect(again.isEmpty)
  }

  /// A beta2/beta3 install has the old bodies and a marker with no hashes. Its
  /// starters that still carry the mark are refreshed once, so the shorter briefs
  /// reach the people who asked for them.
  @Test
  func aLegacyInstallGetsTheNewBodiesOnce() throws {
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    var old = StarterTemplates.getTheBuildGreen
    old.body = "The build is failing. A long old brief with {test_command} in the done check."
    try TemplateFileCodec.encode(old)
      .write(to: home.appendingPathComponent(old.fileName), atomically: true, encoding: .utf8)
    try Data().write(to: home.appendingPathComponent(TemplateStorage.seededMarker))

    let refreshed = try storage.seedStartersIfNeeded([StarterTemplates.getTheBuildGreen])
    #expect(refreshed.map(\.name) == ["Get the build green"])
    #expect(
      storage.load(projectPath: nil).first?.body == StarterTemplates.getTheBuildGreen.body)
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
