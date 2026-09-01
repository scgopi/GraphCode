import ComposableArchitecture
import Foundation
import GraphcodeKit

/// Save-as-template — the sheet's state, what it writes, and where it lands. Split
/// from `ProjectFeature+Templates.swift` because saving and applying are two
/// separate verbs that happen to share a state bag; see PROMPT_TEMPLATES.md
/// § Save as template and § Storage.
extension ProjectFeature {
  /// What Save-as-template is about to write, as the sheet's one binding target.
  /// The template is fully built by the reducer — the sheet edits only its name
  /// and where it lands.
  struct TemplateSaveContext: Equatable, Identifiable {
    let id: UUID
    var name: String
    var scope: TemplateOrigin
    var template: PromptTemplate
    /// Whether this folder can take a `.graphcode/templates` — the sheet greys the
    /// project option out rather than offering a save that silently falls home.
    var projectCanSave: Bool

    init(
      name: String, scope: TemplateOrigin, template: PromptTemplate, projectCanSave: Bool
    ) {
      self.id = UUID()
      self.name = name
      self.scope = scope
      self.template = template
      self.projectCanSave = projectCanSave
    }
  }

  /// The quiet line after a save — the template as it landed, plus the other
  /// location it could be moved to. Never a modal; see PROMPT_TEMPLATES.md § Storage.
  struct TemplateSaveNotice: Equatable {
    var template: PromptTemplate
    var landedInProject: Bool
    var otherOffer: String {
      landedInProject ? "Keep it at home instead" : "Put it in the project instead"
    }
  }

  /// Save-as-template: the sheet, where the file lands, and the quiet line after
  /// (PROMPT_TEMPLATES.md § Save as template).
  func templateSaveReducer(
    _ state: inout State, _ action: Action
  ) -> Effect<Action> {
    switch action {
    case .saveTemplateTapped:
      guard let draft = templateDraftContext(&state) else { return .none }
      state.templates.pendingSave = draft
      return .none

    case .saveLoopTemplateTapped(let nodeID):
      guard let context = templateContext(fromNode: nodeID, in: &state) else { return .none }
      state.templates.pendingSave = context
      return .none

    case .saveTemplateCancelled:
      state.templates.pendingSave = nil
      return .none

    case .saveTemplateConfirmed:
      return confirmSaveTemplate(&state)

    case .templateSaved(let template):
      state.templates.saveNotice = TemplateSaveNotice(
        template: template, landedInProject: template.origin.isProject)
      return .none

    case .templateSaveNoticeDismissed:
      state.templates.saveNotice = nil
      return .none

    case .templateRelocationTapped:
      return relocateTemplate(&state)

    default:
      return .none
    }
  }

  // MARK: - Saving

  /// The dialog's own save context — built from what the form holds *right now*.
  /// Values the human typed into the applied template's `{token}` positions go
  /// back as tokens, not baked in: the filled text is matched against the brief
  /// the template carried, and only a clean match rewinds to `{token}`.
  func templateDraftContext(_ state: inout State) -> TemplateSaveContext? {
    let text = state.currentBriefText
    guard
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || state.draftLoopType == .composite
    else { return nil }
    var body = text
    if let applied = state.templates.applied, applied.brief != text,
      PromptTemplate.tokenValues(of: text, against: applied.brief) != nil
    {
      // The human typed over the template's tokens and changed nothing else — a clean
      // match is the proof of that — so the save offers those values back as tokens
      // rather than baking them in.
      body = applied.brief
    }
    let shape = state.draftLoopType == .sketch ? nil : state.draftLoopType
    var settings = TemplateSettings()
    settings.backend = Self.templateBackend(state.draftBackend)
    if shape == .goalBased {
      settings.doneCheck =
        state.draftPredicate.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil : state.draftPredicate
      settings.metric =
        state.draftMetric.trimmingCharacters(in: .whitespaces).isEmpty
        ? nil : state.draftMetric
    }
    if shape == .timeBased {
      settings.cadence = state.draftInterval.directiveValue(custom: state.draftCustomInterval)
    }
    if shape == .turnBased {
      settings.pausesBeforeWritesOnly = state.draftPausesBeforeWritesOnly
    }
    if shape == .composite, let subGraph = state.draftSubGraph, !subGraph.nodes.isEmpty {
      settings.graphJSON = TemplateSettings.graphJSON(for: subGraph)
    }
    if case .newBranch = state.draftWorktree,
      !state.draftBranch.trimmingCharacters(in: .whitespaces).isEmpty
    {
      settings.branch = state.draftBranch.trimmingCharacters(in: .whitespaces)
    }
    let hadSettings = shape != nil || !settings.isEmpty
    let name =
      state.draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
      ? (state.templates.applied?.name ?? Self.name(fromBrief: body))
      : state.draftTitle
    let template = PromptTemplate(
      name: name,
      body: body,
      shape: shape,
      settings: hadSettings ? settings : nil,
      origin: .home)
    return TemplateSaveContext(
      name: name, scope: .home, template: template,
      projectCanSave: templateLibrary.projectIsWritable(state.graph.project.path))
  }

  /// A card's save context — a finished loop is the most common thing someone
  /// wants to reuse. Saving a shaped loop captures its type and settings
  /// alongside the text; saving a Main loop captures text only.
  func templateContext(fromNode nodeID: UUID, in state: inout State) -> TemplateSaveContext? {
    guard let node = state.graph.nodes[id: nodeID] else { return nil }
    var settings = TemplateSettings()
    settings.backend = Self.templateBackend(node.backend)
    var body = ""
    let shape: LoopType?
    switch node.loopType {
    case .sketch:
      shape = nil
      body = node.firstInstruction ?? ""
    case .goalBased:
      shape = .goalBased
      body = node.goal?.summary ?? ""
      settings.doneCheck = node.goal?.predicate
      settings.metric = node.goal?.metricCommand
    case .timeBased:
      shape = .timeBased
      let prompt = node.triggerPrompt ?? ""
      let task = SessionPrompt.firstPass(of: prompt) ?? prompt
      body = task
      settings.cadence = SessionPrompt.recurrence(of: prompt)?.interval
    case .turnBased:
      shape = .turnBased
      body = node.firstInstruction ?? ""
      settings.pausesBeforeWritesOnly = node.pausesBeforeWritesOnly
    case .composite:
      shape = .composite
      body = node.title
      if let subGraph = node.subGraph, !subGraph.nodes.isEmpty {
        settings.graphJSON = TemplateSettings.graphJSON(for: subGraph)
      }
    }
    guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shape == .composite
    else { return nil }
    let hadSettings = shape != nil || !settings.isEmpty
    let template = PromptTemplate(
      name: node.title,
      body: body,
      shape: shape,
      settings: hadSettings ? settings : nil,
      origin: .home)
    return TemplateSaveContext(
      name: node.title, scope: .home, template: template,
      projectCanSave: templateLibrary.projectIsWritable(state.graph.project.path))
  }

  /// A template's name when nobody typed one: the brief's own first line — the
  /// same line the picker shows, so a file saved this way reads the same in both.
  static func name(fromBrief brief: String) -> String {
    let first =
      brief
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
      .first.map(String.init) ?? brief
    let trimmed = first.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 64 ? String(trimmed.prefix(61)) + "…" : trimmed
  }

  func confirmSaveTemplate(_ state: inout State) -> Effect<Action> {
    guard var context = state.templates.pendingSave else { return .none }
    let name = context.name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return .none }
    context.name = name
    // `renamed(to:)` rather than assigning `name`: the filename is derived from the
    // name and stored, so a sheet rename that only set `name` would write the file
    // under the draft's old slug and print a path that doesn't match what was typed.
    let template = {
      // A fresh id per save: two saves of the same brief are two templates, and the
      // id is what a following loop resolves by.
      var built = context.template.renamed(to: name)
      built.id = UUID()
      return built
    }()
    state.templates.pendingSave = nil
    let projectPath = state.graph.project.path
    let scope = context.scope
    let library = templateLibrary
    return .run { send in
      guard let (saved, _) = try? await library.save(template, scope, projectPath)
      else { return }
      await send(.templateLibraryChanged(await library.load(projectPath)))
      await send(.templateSaved(saved))
    }
  }

  func relocateTemplate(_ state: inout State) -> Effect<Action> {
    guard let notice = state.templates.saveNotice else { return .none }
    state.templates.saveNotice = nil
    let projectPath = state.graph.project.path
    let destination: TemplateOrigin = notice.landedInProject ? .home : .project(projectPath)
    let library = templateLibrary
    return .run { send in
      // What `move` *returns* is where the file is, which is not always where it was
      // asked to go: a project folder that won't take a `.graphcode/templates` sends
      // the template home. Reporting the request instead would tell the human their
      // template is somewhere it isn't.
      guard let moved = try? await library.move(notice.template, destination, projectPath)
      else { return }
      await send(.templateLibraryChanged(await library.load(projectPath)))
      await send(.templateSaved(moved))
    }
  }

  /// One more use of this template, recorded app-locally. Never a write to the file:
  /// applying a template must not dirty a repository's working tree, and a project
  /// folder may not even be writable (PROMPT_TEMPLATES.md § Storage).
  func countUse(of template: PromptTemplate, in projectPath: String) -> Effect<Action> {
    let library = templateLibrary
    return .run { send in
      library.recordUse(template)
      await send(.templateLibraryChanged(await library.load(projectPath)))
    }
  }

  /// The agent a template should carry: one it *names*, or nothing at all. A save
  /// that always wrote the current backend would make `TemplateSettings.backend`'s
  /// "absent means the app's own default stands" unreachable, and hand a teammate a
  /// template pinned to an agent they may not have installed.
  static func templateBackend(_ backend: CLISessionBackendKind) -> CLISessionBackendKind? {
    backend == GraphcodeSettingsStore.load().defaultBackend ? nil : backend
  }
}
