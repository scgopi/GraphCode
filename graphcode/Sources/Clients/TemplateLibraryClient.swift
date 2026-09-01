import Dependencies
import Foundation
import GraphcodeKit

/// The template library, as the app sees it — the bridge between
/// `TemplateStorage` (pure Foundation, shared with the daemon) and the form.
///
/// The watch stream is what makes the library live: an external edit or a `git
/// pull` shows up without a relaunch, which is the design's whole argument for
/// reading templates from files rather than holding them in the app.
struct TemplateLibraryClient: Sendable {
  var load: @Sendable (_ projectPath: String?) async -> [PromptTemplate]
  /// Saves and answers what actually landed — a read-only checkout falls back to
  /// home, and the caller says so rather than pretending the save went where it
  /// was asked.
  var save:
    @Sendable (_ template: PromptTemplate, _ origin: TemplateOrigin, _ projectPath: String?)
      async throws -> (template: PromptTemplate, origin: TemplateOrigin)
  /// Answers with the template as it landed — origin *and* filename, because a
  /// destination that already holds a template of that name gives it another.
  var move:
    @Sendable (_ template: PromptTemplate, _ destination: TemplateOrigin, _ projectPath: String?)
      async throws -> PromptTemplate
  var delete: @Sendable (_ template: PromptTemplate) async throws -> Void
  /// Fires once per change to either location while the stream lives.
  var watch: @Sendable (_ projectPath: String?) -> AsyncStream<Void>
  /// Resolves a template by id — the same read the daemon performs when a
  /// following loop next runs.
  var template: @Sendable (_ id: UUID, _ projectPath: String?) async -> PromptTemplate?
  /// Whether a project folder can take a `.graphcode/templates` — the save sheet
  /// greys the project option out rather than offering a save that falls back
  /// silently. Answering must not *create* the folder: nothing lands in a checkout
  /// until a save asks for it.
  var projectIsWritable: @Sendable (_ projectPath: String) -> Bool
  /// One more use of this template, as the picker counts them. App-local: applying a
  /// template must never write to the file, which may live in a repository.
  var recordUse: @Sendable (_ template: PromptTemplate) -> Void
}

extension TemplateLibraryClient: DependencyKey {
  static let liveValue = TemplateLibraryClient(
    load: { projectPath in
      let storage = TemplateStorage.shared
      let templates = await Task.detached(priority: .userInitiated) {
        storage.load(projectPath: projectPath)
      }.value
      return overlayUseCounts(templates)
    },
    save: { template, origin, projectPath in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.save(template, to: origin, projectPath: projectPath)
      }.value
    },
    move: { template, destination, projectPath in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.move(template, to: destination, projectPath: projectPath)
      }.value
    },
    delete: { template in
      try await Task.detached(priority: .userInitiated) {
        try TemplateStorage.shared.delete(template)
      }.value
    },
    watch: { projectPath in
      TemplateStorage.shared.watch(projectPath: projectPath)
    },
    template: { id, projectPath in
      await Task.detached(priority: .userInitiated) {
        TemplateStorage.shared.template(withID: id, projectPath: projectPath)
      }.value
    },
    projectIsWritable: { projectPath in
      let storage = TemplateStorage.shared
      return storage.canWrite(to: storage.projectDirectory(projectPath))
    },
    recordUse: { template in
      bumpUseCount(for: template)
    }
  )

  static let testValue = TemplateLibraryClient(
    load: { _ in [] },
    save: { _, _, _ in (PromptTemplate(name: "", body: ""), .home) },
    move: { template, _, _ in template },
    delete: { _ in },
    watch: { _ in AsyncStream { $0.finish() } },
    template: { _, _ in nil },
    projectIsWritable: { _ in false },
    recordUse: { _ in }
  )

  /// The use count is app-local (UserDefaults, keyed on filename + origin) and is
  /// never written back into a file — applying a template must not dirty a
  /// repository's working tree. See `PromptTemplate.useCount`.
  static func overlayUseCounts(_ templates: [PromptTemplate]) -> [PromptTemplate] {
    let defaults = UserDefaults.standard
    return templates.map { template in
      var overlaid = template
      overlaid.useCount = defaults.integer(forKey: Self.useCountKey(template))
      return overlaid
    }
  }

  private static func bumpUseCount(for template: PromptTemplate) {
    let defaults = UserDefaults.standard
    let key = Self.useCountKey(template)
    defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
  }

  private static func useCountKey(_ template: PromptTemplate) -> String {
    let origin: String
    switch template.origin {
    case .home: origin = "home"
    case .project(let path): origin = path
    }
    return "templateUseCount.\(origin).\(template.fileName)"
  }
}

extension DependencyValues {
  var templateLibrary: TemplateLibraryClient {
    get { self[TemplateLibraryClient.self] }
    set { self[TemplateLibraryClient.self] = newValue }
  }
}
