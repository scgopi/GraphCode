import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Save-as-template: what each entry point captures, where the file lands, and the
/// quiet line afterwards (PROMPT_TEMPLATES.md § Save as template, § Storage).
/// Applying lives next door in `TemplateApplyTests`.
@Suite
struct TemplateSaveTests {
  private static let project = ProjectRef(path: "/tmp/template-save", name: "save")

  private func makeStore(
    _ templates: [PromptTemplate] = [], loopType: LoopType = .sketch
  ) -> TestStoreOf<ProjectFeature> {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    state.draftLoopType = loopType
    return TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in templates }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.gitClient.listWorktrees = { _ in [] }
      $0.orchestratorClient.send = { _ in }
    }
  }

  /// Saving from the dialog offers the human's token values back as tokens, not
  /// baked-in literals (PROMPT_TEMPLATES.md § Save as template).
  @Test
  @MainActor
  func savingFromTheDialogOffersTypedValuesBackAsTokens() async throws {
    let template = PromptTemplate(
      id: UUID(), name: "Review the branch", body: "Review the changes for {branch}.",
      shape: .goalBased, origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    // The human fills the token by typing over it.
    await store.send(.binding(.set(\.draftGoal, "Review the changes for feat/x.")))
    await store.send(.saveTemplateTapped)
    let context = try #require(store.state.templates.pendingSave)
    // The saved file asks the question again instead of hard-coding this branch.
    #expect(context.template.body == "Review the changes for {branch}.")
    #expect(context.name == "Review the branch")
  }

  /// Text that isn't a clean fill of the template's tokens is saved as written —
  /// recovery must never guess.
  @Test
  @MainActor
  func savingRewrittenTextKeepsItAsWritten() async throws {
    let template = PromptTemplate(
      id: UUID(), name: "Review the branch", body: "Review the changes for {branch}.",
      shape: .goalBased, origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    await store.send(.binding(.set(\.draftGoal, "Audit the whole diff history instead.")))
    await store.send(.saveTemplateTapped)
    let context = try #require(store.state.templates.pendingSave)
    #expect(context.template.body == "Audit the whole diff history instead.")
  }

  @Test
  @MainActor
  func aCardSaveCapturesTheShapeAndItsSettings() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    let node = LoopNode(
      title: "Review the diff", loopType: .goalBased,
      goal: GoalSpec(
        summary: "Read every changed file", predicate: "make test",
        metricCommand: "./scripts/score.sh"),
      backend: .copilotCLI)
    state.graph.nodes.append(node)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.saveLoopTemplateTapped(node.id))
    let context = try #require(store.state.templates.pendingSave)
    #expect(context.name == "Review the diff")
    #expect(context.template.shape == .goalBased)
    #expect(context.template.body == "Read every changed file")
    #expect(context.template.settings?.doneCheck == "make test")
    #expect(context.template.settings?.metric == "./scripts/score.sh")
    // Carried because it differs from the default — a loop that deliberately runs on
    // another agent is a fact about the brief.
    #expect(context.template.settings?.backend == .copilotCLI)
    #expect(context.scope == .home)
  }

  @Test
  @MainActor
  func aMainCardSaveCapturesTextOnly() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    let node = LoopNode(
      title: "Where does this live?", loopType: .sketch, firstInstruction: "Find the cap.")
    state.graph.nodes.append(node)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.saveLoopTemplateTapped(node.id))
    let context = try #require(store.state.templates.pendingSave)
    #expect(context.template.shape == nil)
    #expect(context.template.body == "Find the cap.")
    // The agent is only carried when the template *names* one. This loop runs on the
    // app's own default, so the template says nothing and whoever uses it keeps
    // theirs — see `TemplateSettings.backend`.
    #expect(context.template.settings?.backend == nil)
    #expect(context.template.settings?.doneCheck == nil)
  }

  @Test
  @MainActor
  func aTimedCardSaveCapturesItsCadence() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    let node = LoopNode(
      title: "Nightly dependency review", loopType: .timeBased,
      triggerPrompt: "/loop daily Check for updates worth taking")
    state.graph.nodes.append(node)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.saveLoopTemplateTapped(node.id))
    let context = try #require(store.state.templates.pendingSave)
    #expect(context.template.shape == .timeBased)
    #expect(context.template.body == "Check for updates worth taking")
    #expect(context.template.settings?.cadence == "daily")
  }

  @Test
  @MainActor
  func savingLandsHomeAndOffersTheProject() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    let template = PromptTemplate(
      id: UUID(), name: "Review the diff", body: "Read the diff.", shape: .goalBased,
      settings: TemplateSettings(doneCheck: "make test"), origin: .home)
    state.templates.pendingSave = ProjectFeature.TemplateSaveContext(
      name: "Review the diff", scope: .home, template: template, projectCanSave: true)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.templateLibrary.save = { saved, origin, _ in
        #expect(origin == .home)
        var landed = saved
        landed.origin = origin
        return (landed, origin)
      }
      $0.gitClient.listWorktrees = { _ in [] }
    }

    let savedBox = LockIsolated<String?>(nil)
    store.dependencies.templateLibrary.save = { saved, origin, _ in
      #expect(origin == .home)
      savedBox.withValue { $0 = saved.name }
      var landed = saved
      landed.origin = origin
      return (landed, origin)
    }

    store.exhaustivity = .off
    await store.send(.saveTemplateConfirmed)
    #expect(await savedBox.value == "Review the diff")
    // The save's effect reports what landed — receive is how this suite waits
    // for an effect's actions.
    await store.receive(\.templateLibraryChanged)
    await store.receive(\.templateSaved)
    let notice = try #require(store.state.templates.saveNotice)
    #expect(notice.landedInProject == false)
    #expect(notice.otherOffer == "Put it in the project instead")
    #expect(store.state.templates.pendingSave == nil)
  }

  /// Renaming in the save sheet has to reach the filename too — a template saved as
  /// "Nightly sweep" must not land in `untitled.md`.
  @Test
  @MainActor
  func renamingInTheSheetLandsUnderTheNewFilename() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    state.templates.pendingSave = ProjectFeature.TemplateSaveContext(
      name: "Untitled", scope: .home,
      template: PromptTemplate(name: "Untitled", body: "Read the diff."), projectCanSave: false)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.gitClient.listWorktrees = { _ in [] }
    }
    let written = LockIsolated<String?>(nil)
    store.dependencies.templateLibrary.save = { saved, origin, _ in
      written.withValue { $0 = saved.fileName }
      var landed = saved
      landed.origin = origin
      return (landed, origin)
    }
    store.exhaustivity = .off

    await store.send(
      .binding(
        .set(
          \.templates.pendingSave,
          {
            var context = state.templates.pendingSave!
            context.name = "Nightly sweep"
            return context
          }())))
    await store.send(.saveTemplateConfirmed)
    #expect(written.value == "nightly-sweep.md")
  }

  /// The quiet line says where the file *is*, which is not always where it was asked
  /// to go: a project that can't take one sends the template home.
  @Test
  @MainActor
  func relocationReportsWhereItActuallyLanded() async throws {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    let template = PromptTemplate(name: "Review the diff", body: "Read the diff.")
    state.templates.saveNotice = ProjectFeature.TemplateSaveNotice(
      template: template, landedInProject: false)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.gitClient.listWorktrees = { _ in [] }
      // The project refused it; the move fell back to home and says so.
      $0.templateLibrary.move = { template, _, _ in
        var landed = template
        landed.origin = .home
        return landed
      }
    }
    store.exhaustivity = .off

    await store.send(.templateRelocationTapped)
    await store.receive(\.templateLibraryChanged)
    await store.receive(\.templateSaved)
    let notice = try #require(store.state.templates.saveNotice)
    #expect(notice.landedInProject == false)
    #expect(notice.otherOffer == "Put it in the project instead")
  }

  /// The quiet line is quiet, not permanent — it shares the footer with the reason
  /// Create is disabled.
  @Test
  @MainActor
  func theSaveNoticeCanBeDismissed() async {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    state.templates.saveNotice = ProjectFeature.TemplateSaveNotice(
      template: PromptTemplate(name: "x", body: "y"), landedInProject: false)
    let store = TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in [] }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.gitClient.listWorktrees = { _ in [] }
    }
    store.exhaustivity = .off
    await store.send(.templateSaveNoticeDismissed)
    #expect(store.state.templates.saveNotice == nil)
  }

}
