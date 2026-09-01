import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// The ⌘T picker and what it fills: grouping and sort order, search, and the
/// unfilled-token gate that keeps ⌘⏎ and Start honest (PROMPT_TEMPLATES.md § Tests).
@Suite
struct TemplatePickerTests {
  private static let project = ProjectRef(path: "/tmp/template-picker", name: "picker")

  private func makeStore(_ templates: [PromptTemplate]) -> TestStoreOf<ProjectFeature> {
    TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: Self.project))
    ) {
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

  private func homeTemplate(
    _ name: String, body: String, shape: LoopType? = nil
  ) -> PromptTemplate {
    PromptTemplate(id: UUID(), name: name, body: body, shape: shape, origin: .home)
  }

  @Test
  @MainActor
  func projectTemplatesSortAboveHomeOnesAndWithinByName() async {
    let library = [
      homeTemplate("Zebra check", body: "zebra body"),
      homeTemplate("Alpha check", body: "alpha body"),
      PromptTemplate(
        id: UUID(), name: "Aardvark review", body: "committed body", shape: .goalBased,
        origin: .project(Self.project.path)),
    ]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    // Opening the picker re-reads the library; the test makes the same moment
    // deterministic by delivering the load itself.
    await store.send(.templateLibraryChanged(library))
    // Grouped: the project's committed templates first, then the home ones —
    // each group alphabetised by name.
    let rows = store.state.templatePickerRows
    #expect(rows.map(\.template.name) == ["Aardvark review", "Alpha check", "Zebra check"])
    #expect(rows[0].scope == .project)
    #expect(rows[1].scope == .home)
    #expect(rows[2].scope == .home)
    #expect(store.state.templates.selectionIndex == 0)
  }

  @Test
  @MainActor
  func searchMatchesNameAndBody() async {
    let library = [
      homeTemplate("Review the diff", body: "Read every changed file against the style guide"),
      homeTemplate("Nightly dependency review", body: "Check for updates worth taking"),
    ]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateQueryChanged("style"))
    // "style" appears in a body, not in a name — the brief is searchable too.
    #expect(store.state.templatePickerRows.map(\.template.name) == ["Review the diff"])
    #expect(store.state.templates.selectionIndex == 0)
  }

  @Test
  @MainActor
  func keyboardSelectionWalksBothGroups() async {
    let library = [
      homeTemplate("First", body: "one"),
      homeTemplate("Second", body: "two"),
      homeTemplate("Third", body: "three"),
    ]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateSelectionMoved(1))
    #expect(store.state.templates.selectionIndex == 1)
    await store.send(.templateSelectionMoved(5))
    // The last row is the furthest ↓ goes.
    #expect(store.state.templates.selectionIndex == 2)
    await store.send(.templateSelectionMoved(-9))
    // ↑ from the top stays at the top rather than wrapping into a trap.
    #expect(store.state.templates.selectionIndex == 0)
  }

  @Test
  @MainActor
  func fillingSetsTheBriefAndFocusesIt() async {
    let template = PromptTemplate(
      id: UUID(), name: "Trace a symbol", body: "Trace {symbol} through the codebase.",
      shape: nil, origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateChosen(template.id))
    #expect(store.state.draftSketchNote == "Trace {symbol} through the codebase.")
    #expect(store.state.templates.focusRequest == .brief)
    #expect(store.state.unfilledTokens == ["symbol"])
    #expect(store.state.draftBlocksOnTokens)
    #expect(store.state.templates.applied?.name == "Trace a symbol")
    // The form was sitting on Goal; a shapeless template means Main, and the
    // switch it made is a shape it set — so Undo can put the form back.
    #expect(store.state.draftLoopType == .sketch)
    #expect(store.state.templates.applied?.setFields == [.shape, .brief])
  }

  /// ⌘⏎ is "start now", and a brief with a hole in it is not one: with an unfilled
  /// token the launch degrades to the fill, and nothing is created.
  @Test
  @MainActor
  func launchWithAnUnfilledTokenOnlyFills() async {
    let template = PromptTemplate(
      id: UUID(), name: "Trace a symbol", body: "Trace {symbol} through the codebase.",
      shape: nil, origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off
    store.dependencies.orchestratorClient.send = { _ in
      Issue.record("nothing should be created while a token is unfilled")
      return ()
    }

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateLaunched(template.id))
    #expect(store.state.draftSketchNote == "Trace {symbol} through the codebase.")
    #expect(!store.state.showingNewNodeForm)
  }

  /// ⌘⏎ with nothing left to fill starts the loop immediately — the whole point
  /// of the shortcut.
  @Test
  @MainActor
  func launchWithNothingUnfilledStartsImmediately() async {
    let sent = LockIsolated<[GraphCommand]>([])
    let template = PromptTemplate(
      id: UUID(), name: "Trace a symbol", body: "Trace it through the codebase.",
      shape: nil, origin: .home)
    let library = [template]
    let store = makeStore(library)
    store.exhaustivity = .off
    store.dependencies.orchestratorClient.send = { command in
      if case .graphCommand(_, let inner) = command {
        sent.withValue {
          if case .createNode = inner { $0.append(inner) }
        }
      }
      return ()
    }

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    await store.send(.templateLaunched(template.id))
    #expect(sent.value.count == 1)
    #expect(!store.state.showingNewNodeForm)
  }

  /// Starters and a person's own templates are two sections for good — scaffolding
  /// and a library are different things — and the starters keep their shipped order,
  /// because the group is a ladder: lead a team, then Goal, then Timed, then the rest.
  @Test
  @MainActor
  func startersKeepTheirLadderOrderAndYourOwnSitBelow() async {
    // Deliberately handed over scrambled and alphabetically hostile.
    let shipped = StarterTemplates.all
    let scrambled = Array(shipped.reversed())
    let mine = homeTemplate("Aardvark brief", body: "Would sort first if names decided.")
    let library = scrambled + [mine]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    let rows = store.state.templatePickerRows
    #expect(rows.map(\.scope) == Array(repeating: .starter, count: shipped.count) + [.home])
    #expect(rows.prefix(shipped.count).map(\.template.name) == shipped.map(\.name))
    #expect(rows.first?.template.name == "Lead a team toward a goal")
    #expect(rows.last?.template.name == "Aardvark brief")
    #expect(ProjectFeature.TemplatePickerScope.home.displayName == "Your templates")
  }

  /// The ladder, spelled out: the team-leading brief first, then every Goal, then
  /// every Timed, then the rest.
  @Test
  func theStarterLadderIsLeadThenGoalThenTimed() {
    let shapes = StarterTemplates.all.map { $0.shape }
    #expect(StarterTemplates.all[0].name == "Lead a team toward a goal")
    #expect(shapes[0] == nil)
    let goals = shapes.dropFirst().prefix { $0 == .goalBased }
    #expect(goals.count == 3)
    let timed = shapes.dropFirst(1 + goals.count).prefix { $0 == .timeBased }
    #expect(timed.count == 2)
    #expect(StarterTemplates.priority(of: StarterTemplates.all[0].id) == 0)
    #expect(StarterTemplates.priority(of: UUID()) == StarterTemplates.all.count)
  }

  /// A project's committed templates outrank the shipped ones, always — the rule the
  /// storage design hangs on does not bend for scaffolding.
  @Test
  @MainActor
  func projectTemplatesStillOutrankStarters() async {
    var starter = homeTemplate("Get the build green", body: "Fix the build.", shape: .goalBased)
    starter.isStarter = true
    let committed = PromptTemplate(
      id: UUID(), name: "Team review", body: "Ours.", shape: .goalBased,
      origin: .project(Self.project.path))
    let library = [starter, committed]
    let store = makeStore(library)
    store.exhaustivity = .off

    await store.send(.templatesButtonTapped)
    await store.send(.templateLibraryChanged(library))
    #expect(store.state.templatePickerRows.map(\.scope) == [.project, .starter])
  }

  /// The empty canvas offers the shipped picks, and offers back only what is still on
  /// disk — a starter somebody deleted is not pushed at them again.
  @Test
  @MainActor
  func theCanvasOffersTheFirstLaunchPicksThatSurvive() async {
    let seeded = StarterTemplates.firstLaunchPicks
    let store = makeStore(seeded)
    store.exhaustivity = .off

    await store.send(.templateLibraryChanged(seeded))
    #expect(store.state.firstLaunchStarters.map(\.name) == seeded.map(\.name))

    // One deleted: the row shrinks rather than offering a template that isn't there.
    await store.send(.templateLibraryChanged(Array(seeded.dropFirst())))
    #expect(store.state.firstLaunchStarters.map(\.name) == seeded.dropFirst().map(\.name))
  }

  /// Starting from the canvas opens the dialog with the template already applied —
  /// one click from an empty canvas to a filled-in brief.
  @Test
  @MainActor
  func startingFromTheCanvasOpensTheDialogFilledIn() async {
    let starter = StarterTemplates.firstLaunchPicks[1]  // Get the build green (Goal)
    let store = makeStore([starter])
    store.exhaustivity = .off

    await store.send(.templateLibraryChanged([starter]))
    await store.send(.startFromTemplateTapped(starter.id))
    #expect(store.state.showingNewNodeForm)
    #expect(store.state.draftLoopType == .goalBased)
    #expect(store.state.templates.applied?.name == "Get the build green")
    // Its token lives in the done check, so that is what Start is waiting on.
    #expect(store.state.unfilledTokens == ["test_command"])
    #expect(store.state.draftBlocksOnTokens)
  }

  @Test
  @MainActor
  func theTypeLabelNamesTheShapeAndItsQualifier() {
    let timed = PromptTemplate(
      id: UUID(), name: "Nightly", body: "Check dependencies.",
      shape: .timeBased, settings: TemplateSettings(cadence: "daily"), origin: .home)
    let composite = PromptTemplate(
      id: UUID(), name: "Pipeline", body: "Hand work along.", shape: .composite,
      settings: TemplateSettings(
        graphJSON: TemplateSettings.graphJSON(
          for: LoopGraph(
            project: ProjectRef(path: "sub", name: "sub"),
            nodes: [
              LoopNode(title: "A"), LoopNode(title: "B"), LoopNode(title: "C"),
            ]))),
      origin: .home)
    let main = PromptTemplate(
      id: UUID(), name: "Poke", body: "Where does this live?", origin: .home)

    #expect(
      ProjectFeature.TemplatePickerRow(template: timed, scope: .home).typeLabel == "Timed · daily")
    #expect(
      ProjectFeature.TemplatePickerRow(template: composite, scope: .home).typeLabel
        == "Composite · 3 loops")
    #expect(ProjectFeature.TemplatePickerRow(template: main, scope: .home).typeLabel == "Main")
    #expect(timed.settingsSummary == ["runs every daily"])
    #expect(main.settingsSummary.isEmpty)
  }
}
