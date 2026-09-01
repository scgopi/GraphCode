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
