import Foundation
import GraphcodeKit
import Testing

/// Editing a template that already exists — the Settings editor's Save. The rule
/// this suite exists for: **the id survives**, so every timed and composite loop
/// following the template goes on following it across the edit
/// (PROMPT_TEMPLATES.md § Follow vs snapshot).
@Suite
struct TemplateEditingTests {
  private let home: URL
  private let storage: TemplateStorage

  init() {
    home = FileManager.default.temporaryDirectory
      .appendingPathComponent("template-editing-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    storage = TemplateStorage(
      homeDirectory: home,
      projectDirectory: { _ in
        URL(fileURLWithPath: "/nonexistent", isDirectory: true)
      })
  }

  private func goalTemplate(_ name: String, body: String) -> PromptTemplate {
    PromptTemplate(
      id: UUID(), name: name, body: body, shape: .goalBased,
      settings: TemplateSettings(doneCheck: "make test"), origin: .home)
  }

  // MARK: - Editing

  /// Editing keeps the id, which is the whole point: every timed and composite loop
  /// following this template goes on following it across the edit.
  @Test
  func editingKeepsTheIdSoFollowersStayAttached() throws {
    let (saved, _) = try storage.save(
      goalTemplate("nightly", body: "Check dependencies."), to: .home, projectPath: nil)
    var edited = saved
    edited.body = "Check dependencies and triage."
    edited.id = UUID()  // even if a caller hands over a different id, the file's wins

    let written = try storage.update(edited, replacing: saved)
    #expect(written.id == saved.id)
    #expect(written.fileName == saved.fileName)
    #expect(
      storage.template(withID: saved.id, projectPath: nil)?.body
        == "Check dependencies and triage.")
  }

  /// A rename moves the file and takes the old one with it — but only once the new
  /// one is written, and only when it really is a different file.
  @Test
  func renamingInTheEditorMovesTheFile() throws {
    let (saved, _) = try storage.save(
      goalTemplate("nightly", body: "Check dependencies."), to: .home, projectPath: nil)
    let written = try storage.update(saved.renamed(to: "Nightly sweep"), replacing: saved)

    #expect(written.fileName == "nightly-sweep.md")
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("nightly.md").path))
    #expect(storage.load(projectPath: nil).map(\.name) == ["Nightly sweep"])
    // The id survived the rename, so a following loop still resolves it.
    #expect(storage.template(withID: saved.id, projectPath: nil)?.name == "Nightly sweep")
  }

  /// An edit that doesn't rename must not delete what it just wrote — the same trap
  /// `move` had.
  @Test
  func anEditThatDoesNotRenameKeepsTheFile() throws {
    let (saved, _) = try storage.save(
      goalTemplate("nightly", body: "One."), to: .home, projectPath: nil)
    var edited = saved
    edited.body = "Two."
    _ = try storage.update(edited, replacing: saved)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("nightly.md").path))
    #expect(storage.load(projectPath: nil).map(\.body) == ["Two."])
  }
}
