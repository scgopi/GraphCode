import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// What applying a template does to the form, and how it is taken back — the
/// three rules of the applied state (PROMPT_TEMPLATES.md § Applied state): the
/// shape is stated and marked, every field the template set stays editable, and
/// `Undo the shape` / ✕ return exactly what they should.
@Suite
struct TemplateApplyTests {
  private static let project = ProjectRef(path: "/tmp/template-apply", name: "apply")

  private func makeStore(
    _ templates: [PromptTemplate] = [], loopType: LoopType = .sketch,
    sketchNote: String = ""
  ) -> TestStoreOf<ProjectFeature> {
    var state = ProjectFeature.State(graph: LoopGraph(project: Self.project))
    state.draftLoopType = loopType
    state.draftSketchNote = sketchNote
    return TestStore(initialState: state) {
      ProjectFeature()
    } withDependencies: {
      $0.templateLibrary.load = { _ in templates }
      $0.templateLibrary.watch = { _ in AsyncStream { $0.finish() } }
      $0.templateLibrary.projectIsWritable = { _ in true }
      $0.gitClient.listWorktrees = { _ in [] }
      // A no-op orchestrator: any send that reaches it is asserted by the test
      // that means it, and the rest must not record phantom issues.
      $0.orchestratorClient.send = { _ in }
    }
  }

  private var goalTemplate: PromptTemplate {
    PromptTemplate(
      id: UUID(), name: "Review the diff",
      body: "Read every changed file against the style guide, then list what must change.",
      shape: .goalBased,
      settings: TemplateSettings(
        backend: .claudeCode, doneCheck: "make test", cadence: nil, pausesBeforeWritesOnly: nil,
        branch: "review/patch", metric: "./scripts/score.sh"),
      origin: .home)
  }

  @Test
  @MainActor
  func applyingSetsTheTypeAndEverySetting() async {
    let template = goalTemplate
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    let state = store.state
    #expect(state.draftLoopType == .goalBased)
    #expect(state.draftGoal.contains("style guide"))
    #expect(state.draftPredicate == "make test")
    #expect(state.draftMetric == "./scripts/score.sh")
    #expect(state.isMetricExpanded)
    #expect(state.draftWorktree == .newBranch)
    #expect(state.draftBranch == "review/patch")
    // Every field the template landed is marked, and nothing is locked — the
    // marks are provenance, not permission.
    #expect(state.templateSetFields.contains(.shape))
    #expect(state.templateSetFields.contains(.brief))
    #expect(state.templateSetFields.contains(.doneCheck))
    #expect(state.templateSetFields.contains(.metric))
    #expect(state.templateSetFields.contains(.branch))
    #expect(state.draft.isValid)
  }

  /// An unfilled-token brief keeps Start off; filling it over is what unblocks
  /// the dialog (PROMPT_TEMPLATES.md § What a template carries).
  @Test
  @MainActor
  func anUnfilledTokenBlocksStartAndFillingUnblocksIt() async {
    let tokenised = PromptTemplate(
      id: UUID(), name: "Port {branch}", body: "Port {branch} to the new renderer.",
      shape: .goalBased, origin: .home)
    let library = [tokenised]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(tokenised.id))
    #expect(store.state.unfilledTokens == ["branch"])
    #expect(store.state.draftBlocksOnTokens)
    #expect(store.state.draft.isValid)
    // The two gates are different things: the draft is valid, the token is not.
    #expect(!store.state.draftBlocksOnTokens || store.state.draft.isValid)

    await store.send(.binding(.set(\.draftGoal, "Port feat/x to the new renderer.")))
    #expect(store.state.unfilledTokens.isEmpty)
    #expect(!store.state.draftBlocksOnTokens)
  }

  /// "Undo the shape": type and settings revert, the prompt text stays, and the
  /// loop returns to Main — with the brief carried into the Main note.
  @Test
  @MainActor
  func undoingTheShapeKeepsThePromptAndReturnsToMain() async {
    let template = goalTemplate
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    await store.send(.templateShapeUndone)
    let state = store.state
    #expect(state.draftLoopType == .sketch)
    // The prompt text survived the revert, and it lives in the Main note now.
    #expect(state.draftSketchNote.contains("style guide"))
    #expect(state.draftGoal.isEmpty)
    #expect(state.draftPredicate.isEmpty)
    #expect(state.draftMetric.isEmpty)
    #expect(state.draftWorktree == .none)
    // Only the brief still counts as template-set.
    #expect(state.templateSetFields == [.brief])
  }

  /// The ✕ is the stronger undo: everything the template contributed goes,
  /// including the text, back to the fields as they were before it landed.
  @Test
  @MainActor
  func removingTheChipClearsEverythingTheTemplateContributed() async {
    let template = goalTemplate
    let library = [template]
    let store = makeStore(library, sketchNote: "my own half-written note")
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    #expect(store.state.draftGoal.contains("style guide"))
    await store.send(.templateChipRemoved)
    let restored = store.state
    // Everything back to before: type, settings, and the human's own text.
    #expect(restored.draftLoopType == .sketch)
    #expect(restored.draftSketchNote == "my own half-written note")
    #expect(restored.draftGoal.isEmpty)
    #expect(restored.draftPredicate.isEmpty)
    #expect(restored.draftWorktree == .none)
    #expect(restored.templates.applied == nil)
    #expect(restored.templateSetFields.isEmpty)
  }

  /// A Main template (no shape) applies text only — and its ✕ clears only the
  /// text, because there was never a shape to revert.
  @Test
  @MainActor
  func aShapelessTemplateCarriesOnlyItsText() async {
    let main = PromptTemplate(
      id: UUID(), name: "Where does this live?",
      body: "Trace a symbol through the codebase and report every reader and writer.",
      shape: nil, origin: .home)
    let library = [main]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(main.id))
    #expect(store.state.draftLoopType == .sketch)
    #expect(store.state.templates.applied?.carriesShape == false)
    // No shape to undo — the action leaves the brief exactly where it is.
    await store.send(.templateShapeUndone)
    #expect(store.state.draftSketchNote.contains("Trace a symbol"))
    await store.send(.templateChipRemoved)
    #expect(store.state.draftSketchNote.isEmpty)
    #expect(store.state.templates.applied == nil)
  }

  /// A timed template lands its cadence in the real interval control — the
  /// five-segment picker when the template's cadence is one of them, Custom…
  /// with the value typed in when it isn't.
  @Test
  @MainActor
  func aTimedTemplateSetsItsCadence() async {
    let hourly = PromptTemplate(
      id: UUID(), name: "Hourly sweep", body: "Check the queue.",
      shape: .timeBased, settings: TemplateSettings(cadence: "1h"), origin: .home)
    let odd = PromptTemplate(
      id: UUID(), name: "Odd sweep", body: "Check the queue.",
      shape: .timeBased, settings: TemplateSettings(cadence: "45m"), origin: .home)

    let library = [hourly, odd]
    let store = makeStore(library)
    store.exhaustivity = .off
    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(hourly.id))
    #expect(store.state.draftInterval == .hourly)
    #expect(store.state.templateSetFields.contains(.cadence))
    // Composed prompt is the real thing: GraphCode writes the /loop directive.
    #expect(store.state.composedTriggerPrompt == "/loop 1h Check the queue.")

    await store.send(.templateChosen(odd.id))
    #expect(store.state.draftInterval == .custom)
    #expect(store.state.draftCustomInterval == "45m")
    #expect(store.state.composedTriggerPrompt == "/loop 45m Check the queue.")
  }

  /// A template is "used" when it is applied, not when it is saved — that is what
  /// the picker's "used N×" counts.
  @Test
  @MainActor
  func applyingATemplateCountsAsAUse() async {
    let template = goalTemplate
    let library = [template]
    let used = LockIsolated<[String]>([])
    let store = makeStore(library)
    store.exhaustivity = .off
    store.dependencies.templateLibrary.recordUse = { applied in
      used.withValue { $0.append(applied.name) }
    }

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    await store.receive(\.templateLibraryChanged)
    #expect(used.value == ["Review the diff"])
  }

  /// A `{token}` left in a done check is exactly as unfinished as one left in the
  /// brief — starting would run the literal text.
  @Test
  @MainActor
  func aTokenLeftInASettingBlocksStartToo() async {
    let template = PromptTemplate(
      id: UUID(), name: "Suite check", body: "Get the suite green.", shape: .goalBased,
      settings: TemplateSettings(doneCheck: "make test-{suite}"), origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    #expect(store.state.unfilledTokens == ["suite"])
    #expect(store.state.draftBlocksOnTokens)

    await store.send(.binding(.set(\.draftPredicate, "make test-parser")))
    #expect(store.state.unfilledTokens.isEmpty)
  }

  /// `⇥` walks the fields that still hold a hole, in form order, and cycles — the
  /// design's "One token left to fill · ⇥ to jump to it" has to be true.
  @Test
  @MainActor
  func tabWalksTheFieldsHoldingUnfilledTokens() async {
    let template = PromptTemplate(
      id: UUID(), name: "Suite check", body: "Get {area} green.", shape: .goalBased,
      settings: TemplateSettings(doneCheck: "make test-{suite}"), origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    // ⏎ lands on the brief.
    #expect(store.state.templates.focusRequest == .brief)
    #expect(store.state.tokenFields == [.brief, .doneCheck])

    await store.send(.templateTokenJumpRequested)
    #expect(store.state.templates.focusRequest == .doneCheck)
    // Cycles rather than dead-ending on the last one.
    await store.send(.templateTokenJumpRequested)
    #expect(store.state.templates.focusRequest == .brief)

    // A field the human has filled drops out of the walk.
    await store.send(.binding(.set(\.draftGoal, "Get the parser green.")))
    #expect(store.state.tokenFields == [.doneCheck])
    await store.send(.templateTokenJumpRequested)
    #expect(store.state.templates.focusRequest == .doneCheck)
  }

  /// The field that answers a focus request clears it, so one jump moves one field.
  @Test
  @MainActor
  func aFocusRequestIsConsumedByTheFieldThatAnswersIt() async {
    let store = makeStore()
    store.exhaustivity = .off
    await store.send(.templateTokenJumpRequested)
    await store.send(.templateFocusConsumed)
    #expect(store.state.templates.focusRequest == nil)
  }

  /// The line the design writes, verbatim.
  @Test
  @MainActor
  func theUnfilledTokenLineIsTheDesignsOwn() async {
    let one = PromptTemplate(
      id: UUID(), name: "One", body: "Review {branch}.", shape: .goalBased, origin: .home)
    let two = PromptTemplate(
      id: UUID(), name: "Two", body: "Review {branch} for {ticket}.", shape: .goalBased,
      origin: .home)
    let library = [one, two]
    let store = makeStore(library)
    store.exhaustivity = .off
    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))

    await store.send(.templateChosen(one.id))
    #expect(store.state.unfilledTokenPrompt == "One token left to fill · ⇥ to jump to it")
    await store.send(.templateChosen(two.id))
    #expect(store.state.unfilledTokenPrompt == "2 tokens left to fill · ⇥ to jump to them")

    await store.send(.binding(.set(\.draftGoal, "Review main for GC-1.")))
    #expect(store.state.unfilledTokenPrompt == nil)
  }

  /// ✕ answers "put the form back the way I found it", and that means before *any*
  /// template landed — not before the most recent one.
  @Test
  @MainActor
  func theChipRestoresThePreTemplateDraftAfterTwoApplies() async {
    let first = PromptTemplate(
      id: UUID(), name: "First", body: "First brief.", shape: .goalBased, origin: .home)
    let second = PromptTemplate(
      id: UUID(), name: "Second", body: "Second brief.", shape: .turnBased, origin: .home)
    let library = [first, second]
    let store = makeStore(library, loopType: .sketch, sketchNote: "my own half-written note")
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(first.id))
    await store.send(.templateChosen(second.id))
    await store.send(.templateChipRemoved)
    #expect(store.state.draftLoopType == .sketch)
    #expect(store.state.draftSketchNote == "my own half-written note")
    #expect(store.state.draftGoal.isEmpty)
    #expect(store.state.draftFirstInstruction.isEmpty)
  }

  /// A composite template carries its children into the draft, and the loop it
  /// creates follows the template — that is how an orchestration is shared.
  @Test
  @MainActor
  func aCompositeTemplateCarriesItsChildrenIntoTheDraft() async {
    let graph = LoopGraph(
      project: ProjectRef(path: "review", name: "review"),
      nodes: [
        LoopNode(title: "Reviewer", loopType: .goalBased, goal: GoalSpec(summary: "Find issues"))
      ])
    let composite = PromptTemplate(
      id: UUID(), name: "Review, fix, verify", body: "Hand findings along.",
      shape: .composite,
      settings: TemplateSettings(graphJSON: TemplateSettings.graphJSON(for: graph)),
      origin: .home)
    let library = [composite]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(composite.id))
    #expect(store.state.draftLoopType == .composite)
    // The composite's brief is its name, carried from the template.
    #expect(store.state.draftTitle == "Review, fix, verify")
    #expect(store.state.draftSubGraph?.nodes.map(\.title) == ["Reviewer"])
    #expect(store.state.templateSetFields.contains(.subGraph))
    // The carried loops land inside on Create — re-identified, so a second loop
    // from the same template never collides with the first.
    let draft = store.state.draft
    #expect(draft.subGraph?.nodes.count == 1)
    #expect(draft.createdFromTemplateID == composite.id)
    #expect(draft.templateFollow?.name == "Review, fix, verify")
  }
}
