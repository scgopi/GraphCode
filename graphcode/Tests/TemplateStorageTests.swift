import Foundation
import GraphcodeKit
import Testing

/// Where templates live, how they are read back, and the two rules the design's
/// Storage section hangs everything on: **home is where the app writes by default;
/// the project is also read, and a project file with the same name wins.**
///
/// Every path here is injected into a scratch directory — the real `~/.graphcode`
/// is never touched, for the same reason `SupportDirectoryTests` exists at all.
@Suite
struct TemplateStorageTests {
  private let home: URL
  private let projectPath: String

  init() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("template-storage-tests-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true)
    projectPath = root.appendingPathComponent("repo", isDirectory: true).path
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: URL(fileURLWithPath: projectPath, isDirectory: true), withIntermediateDirectories: true)
  }

  private var storage: TemplateStorage {
    TemplateStorage(
      homeDirectory: home,
      projectDirectory: { path in
        URL(fileURLWithPath: path, isDirectory: true)
          .appendingPathComponent(".graphcode", isDirectory: true)
          .appendingPathComponent("templates", isDirectory: true)
      })
  }

  private var projectTemplatesURL: URL {
    storage.projectDirectory(projectPath)
  }

  private func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }

  private func goalTemplate(_ name: String, body: String = "Read every changed file for {branch}.")
    -> PromptTemplate
  {
    PromptTemplate(
      id: UUID(), name: name, body: body, shape: .goalBased,
      settings: TemplateSettings(doneCheck: "make test"), origin: .home)
  }

  // MARK: - Saving

  @Test
  func homeIsTheDefaultWriteTarget() throws {
    let (_, origin) = try storage.save(
      goalTemplate("review-diff"), to: .home, projectPath: projectPath)
    #expect(origin == .home)
    #expect(
      FileManager.default.fileExists(
        atPath: home.appendingPathComponent("review-diff.md").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: projectTemplatesURL.appendingPathComponent("review-diff.md").path))
  }

  @Test
  func projectSaveWritesOnlyWhereItWasAsked() throws {
    let (_, origin) = try storage.save(
      goalTemplate("review-diff"), to: .project(projectPath), projectPath: projectPath)
    #expect(origin == .project(projectPath))
    #expect(
      FileManager.default.fileExists(
        atPath: projectTemplatesURL.appendingPathComponent("review-diff.md").path))
  }

  /// A read-only checkout falls back to home rather than losing the save — the
  /// rationale in the design is that plenty of repos will not take a new dotfolder,
  /// and the app must be fully usable with home alone.
  @Test
  func aReadOnlyProjectFolderFallsBackToHome() throws {
    let directory = projectTemplatesURL
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard setReadOnly(directory) else {
      Issue.record("could not make the scratch folder read-only on this platform")
      return
    }
    defer { setWritable(directory) }

    let (_, origin) = try storage.save(
      goalTemplate("review-diff"), to: .project(projectPath), projectPath: projectPath)
    #expect(origin == .home)
    #expect(
      FileManager.default.fileExists(
        atPath: home.appendingPathComponent("review-diff.md").path))
  }

  private func setReadOnly(_ url: URL) -> Bool {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: url.path)
    return !FileManager.default.isWritableFile(atPath: url.path)
  }

  private func setWritable(_ url: URL) {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  /// The relocation that isn't one. "Put it in the project instead" against a folder
  /// that can't take a `.graphcode/templates` resolves back to home — which is where
  /// the file already is. Writing the copy and then deleting "the original" would
  /// delete the only copy, so the move has to notice it is a no-op.
  @Test
  func relocatingIntoAnUnwritableProjectKeepsTheTemplate() throws {
    let (saved, _) = try storage.save(
      goalTemplate("review-diff"), to: .home, projectPath: projectPath)
    let home = self.home.appendingPathComponent("review-diff.md")
    #expect(FileManager.default.fileExists(atPath: home.path))

    let unwritable = URL(fileURLWithPath: "/System/Library/graphcode-not-a-real-project").path
    let landed = try storage.move(saved, to: .project(unwritable), projectPath: unwritable)

    #expect(landed.origin == .home)
    #expect(FileManager.default.fileExists(atPath: home.path))
    #expect(storage.load(projectPath: nil).map(\.name) == ["review-diff"])
  }

  /// The relocation that is one: home → project moves the file and says so.
  @Test
  func relocatingIntoAWritableProjectMovesTheFile() throws {
    let (saved, _) = try storage.save(
      goalTemplate("review-diff"), to: .home, projectPath: projectPath)
    let landed = try storage.move(saved, to: .project(projectPath), projectPath: projectPath)

    #expect(landed.origin == .project(projectPath))
    #expect(
      FileManager.default.fileExists(
        atPath: projectTemplatesURL.appendingPathComponent("review-diff.md").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: home.appendingPathComponent("review-diff.md").path))
  }

  /// Two different briefs that happen to share a name are two templates. The second
  /// save takes the next free filename rather than writing over the first.
  @Test
  func aNameCollisionTakesTheNextFilenameRatherThanOverwriting() throws {
    let (first, _) = try storage.save(
      PromptTemplate(name: "Review the diff", body: "The first one."), to: .home,
      projectPath: nil)
    let (second, _) = try storage.save(
      PromptTemplate(name: "Review the diff", body: "A different one."), to: .home,
      projectPath: nil)

    #expect(first.fileName == "review-the-diff.md")
    #expect(second.fileName == "review-the-diff-2.md")
    let bodies = Set(storage.load(projectPath: nil).map(\.body))
    #expect(bodies == ["The first one.", "A different one."])
  }

  /// Asking whether a project can take a template must not put a `.graphcode` in
  /// somebody's checkout: nothing lands there by default (§ Storage).
  @Test
  func askingWhetherTheProjectIsWritableCreatesNothing() {
    #expect(storage.canWrite(to: projectTemplatesURL))
    #expect(!FileManager.default.fileExists(atPath: projectTemplatesURL.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: projectPath).appendingPathComponent(".graphcode").path))
  }

  @Test
  func aRenamedTemplateTakesItsNewFilename() {
    let template = PromptTemplate(name: "Review the diff", body: "Read it.")
    #expect(template.fileName == "review-the-diff.md")
    #expect(template.renamed(to: "Nightly sweep").fileName == "nightly-sweep.md")
    #expect(template.renamed(to: "Nightly sweep").name == "Nightly sweep")
  }

  /// The picker's second line is a sentence, and a command with dots in it is not a
  /// sentence boundary.
  @Test
  func theSummaryLineIsTheFirstSentence() {
    let template = PromptTemplate(
      name: "x", body: "Read every changed file. Then list what must change.")
    #expect(template.summaryLine == "Read every changed file.")
    #expect(
      PromptTemplate(name: "x", body: "Run ./scripts/score.sh and report the number.")
        .summaryLine == "Run ./scripts/score.sh and report the number.")
  }

  /// A value that already looks quoted has to survive the trip — the reader strips
  /// the outer quotes, so the writer has to add its own.
  @Test
  func aValueThatLooksQuotedRoundTrips() throws {
    let template = PromptTemplate(
      name: "x", body: "body", shape: .goalBased,
      settings: TemplateSettings(doneCheck: "\"make test\""))
    let parsed = try #require(
      TemplateFileCodec.decode(TemplateFileCodec.encode(template), origin: .home))
    #expect(parsed.settings?.doneCheck == "\"make test\"")
  }

  // MARK: - Reading

  @Test
  func projectTemplatesSortAboveHomeOnes() {
    write(
      "---\nname: Committed brief\nshape: goal\n---\n\nFrom the project folder.",
      to: projectTemplatesURL.appendingPathComponent("committed.md"))
    write(
      "---\nname: Personal brief\nshape: goal\n---\n\nFrom home.",
      to: home.appendingPathComponent("personal.md"))

    let loaded = storage.load(projectPath: projectPath)
    #expect(loaded.map(\.name) == ["Committed brief", "Personal brief"])
    #expect(loaded[0].origin.isProject)
    #expect(loaded[1].origin == .home)
  }

  /// The collision rule: same filename, project wins. A team's committed version
  /// outranks a personal one — the person can still see theirs by renaming, and the
  /// shared one is the one everyone gets.
  @Test
  func theProjectCopyWinsOnFilenameCollision() {
    write(
      "---\nname: Committed brief\nshape: goal\n---\n\nTeam's version.",
      to: projectTemplatesURL.appendingPathComponent("review.md"))
    write(
      "---\nname: Personal brief\nshape: goal\n---\n\nMine.",
      to: home.appendingPathComponent("review.md"))

    let loaded = storage.load(projectPath: projectPath)
    #expect(loaded.count == 1)
    #expect(loaded[0].body == "Team's version.")
    #expect(loaded[0].origin.isProject)
  }

  /// A project with no template folder is normal — most repos never get one — and
  /// the library is then exactly home's.
  @Test
  func aProjectWithoutTemplatesReadsHomeAlone() {
    write(
      "---\nname: Personal brief\nshape: goal\n---\n\nFrom home.",
      to: home.appendingPathComponent("personal.md"))
    #expect(storage.load(projectPath: projectPath).map(\.name) == ["Personal brief"])
  }

  @Test
  func aTemplateCanBeFoundByItsIdAfterARename() {
    let id = UUID()
    write(
      "---\nid: \(id.uuidString)\nname: Nightly review\nshape: timed\ncadence: daily\n---\n\n"
        + "Check for dependency updates worth taking.",
      to: projectTemplatesURL.appendingPathComponent("nightly-review.md"))
    #expect(storage.template(withID: id, projectPath: projectPath)?.name == "Nightly review")
  }

  /// A half-written or hand-mangled file is skipped, not fatal: one bad file must
  /// not take the whole library down.
  @Test
  func anUnreadableFileIsSkippedNotFatal() {
    write(
      "---\nname: Broken template\nshape: goal\n",  // front matter never closes
      to: home.appendingPathComponent("broken.md"))
    write(
      "---\nname: Good template\nshape: goal\n---\n\nDo the work.",
      to: home.appendingPathComponent("good.md"))
    let loaded = storage.load(projectPath: nil)
    #expect(loaded.map(\.name) == ["Good template"])
  }

  // MARK: - Codec

  @Test
  func theFileRoundTripsThroughItsCodec() throws {
    let template = PromptTemplate(
      id: UUID(), name: "Review the diff", body: "Check {branch} against the style guide.",
      shape: .goalBased,
      settings: TemplateSettings(
        backend: .claudeCode, doneCheck: "make test", cadence: nil, pausesBeforeWritesOnly: nil,
        branch: "review/patch", metric: "make score"),
      origin: .home)

    let text = TemplateFileCodec.encode(template)
    let parsed = TemplateFileCodec.decode(text, origin: .home)

    let roundTripped = try #require(parsed)
    #expect(roundTripped.id == template.id)
    #expect(roundTripped.name == template.name)
    #expect(roundTripped.body == template.body)
    #expect(roundTripped.shape == template.shape)
    #expect(roundTripped.settings == template.settings)
    #expect(roundTripped.tokens == ["branch"])
  }

  /// The shape is written with the human word and read back from either that or
  /// the raw value — both have shipped, and a hand-edited file should load.
  @Test
  func shapeWordsAreReadBackEitherWay() {
    #expect(TemplateShapeWord.parse("goal") == .goalBased)
    #expect(TemplateShapeWord.parse("timed") == .timeBased)
    #expect(TemplateShapeWord.parse("timeBased") == .timeBased)
    #expect(TemplateShapeWord.parse("main") == .sketch)
    #expect(TemplateShapeWord.parse("composite") == .composite)
    #expect(TemplateShapeWord.parse("nonsense") == nil)
  }

  /// A file that is only a prompt is a complete template — front matter is for the
  /// shape, not the text.
  @Test
  func aBarePromptFileLoadsAsMain() throws {
    let parsed = try #require(
      TemplateFileCodec.decode(
        "Trace a symbol through the codebase and report every reader and writer.",
        origin: .home))
    #expect(parsed.shape == nil)
    #expect(parsed.name.hasPrefix("Trace a symbol through the codebase and report"))
    #expect(parsed.body.contains("Trace a symbol"))
  }

  /// A composite template carries its orchestration — the graph in front matter
  /// decodes back to the loops and edges it shipped with.
  @Test
  func aCompositeTemplateCarriesItsGraph() throws {
    let child = LoopNode(
      title: "Reviewer", loopType: .goalBased, goal: GoalSpec(summary: "Find issues"))
    let graph = LoopGraph(
      project: ProjectRef(path: "review-subgraph", name: "review"),
      nodes: [child])
    let json = try #require(TemplateSettings.graphJSON(for: graph))

    let text = """
      ---
      id: \(UUID().uuidString)
      name: Review, fix, verify
      shape: composite
      graph: \(json)
      ---

      A reviewer hands findings to a fixer, which hands the build to a verifier.
      """
    let parsed = try #require(TemplateFileCodec.decode(text, origin: .home))
    let carried = try #require(parsed.settings?.carriedGraph)
    #expect(carried.nodes.map(\.title) == ["Reviewer"])
    #expect(carried.nodes[0].loopType == .goalBased)
  }

  @Test
  func tokensAreExtractedInOrderOfFirstAppearance() {
    #expect(
      PromptTemplate.tokens(in: "Port {branch} for {branch} and {ticket}. Plain {not a token}.")
        == ["branch", "ticket"])
    #expect(PromptTemplate.tokens(in: "No tokens here.").isEmpty)
  }
}
