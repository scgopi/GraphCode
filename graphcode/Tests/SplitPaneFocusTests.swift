import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Which pane of a split has the keyboard.
///
/// Worth pinning because the failure is silent: when nothing tracks this, both panes ask
/// libghostty for focus, both draw a filled cursor, and the only way to find out where
/// your keystrokes went is to type.
@Suite
struct SplitPaneFocusTests {
  /// Temp-directory-backed, like `LoopWorkspaceFeatureTests` — every layout change
  /// persists, and no test may write to the real support directory.
  private func makeStore() -> TestStoreOf<LoopWorkspaceFeature> {
    let node = LoopNode(title: "L", loopType: .goalBased, goal: GoalSpec(summary: "go"))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let store = TestStore(
      initialState: LoopWorkspaceFeature.State(
        node: node, layout: .defaultLayout(forNode: node.id), projectPath: "/tmp/p",
        projectName: "p")
    ) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func anUnsplitTabResolvesToItsOnlyPane() {
    let tab = TerminalLayout.defaultLayout(forNode: UUID()).tabs[0]
    #expect(!tab.isSplit)
    #expect(tab.focusedSurface.id == tab.primary.id)
  }

  @Test
  @MainActor
  func splittingHandsTheKeyboardToTheNewPane() async throws {
    let store = makeStore()
    await store.send(.splitButtonTapped(direction: .vertical))

    let tab = store.state.layout.tabs[0]
    let secondary = try #require(tab.secondary)
    #expect(tab.focusedSurface.id == secondary.id)
    // …and exactly one pane is focused, which is the whole point.
    #expect(tab.primary.id != tab.focusedSurface.id)
  }

  @Test
  @MainActor
  func clickingTheOtherPaneMovesFocusToIt() async {
    let store = makeStore()
    await store.send(.splitButtonTapped(direction: .horizontal))
    let tab = store.state.layout.tabs[0]

    await store.send(.paneFocused(tabID: tab.id, surfaceID: tab.primary.id))
    #expect(store.state.layout.tabs[0].focusedSurface.id == tab.primary.id)
  }

  @Test
  @MainActor
  func closingTheFocusedPaneLeavesTheSurvivorFocusedRatherThanNothing() async {
    let store = makeStore()
    await store.send(.splitButtonTapped(direction: .horizontal))
    let tab = store.state.layout.tabs[0]
    let survivor = tab.primary.id
    let focused = tab.focusedSurface.id

    // Close the pane that currently holds the keyboard — the case where a stale id would
    // otherwise name a pane that no longer exists, leaving the tab unable to be typed in.
    await store.send(.paneClosed(tabID: tab.id, surfaceID: focused))

    let after = store.state.layout.tabs[0]
    #expect(!after.isSplit)
    #expect(after.primary.id == survivor)
    #expect(after.focusedSurface.id == survivor)
  }

  @Test
  func aStaleFocusIDNeverLeavesATabWithNoFocusedPane() {
    // Decoded from an older layout, or pointing at a pane that has since gone: resolving
    // has to land on a real pane either way.
    var tab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: true))
    #expect(tab.focusedSurface.id == tab.primary.id)

    tab.focusedSurfaceID = UUID()
    #expect(tab.focusedSurface.id == tab.primary.id)
  }

  @Test
  func aLayoutSavedBeforePaneFocusExistedStillDecodes() throws {
    // The persisted file for anyone already using graphcode has no `focusedSurfaceID`.
    let json = """
      {"tabs":[{"id":"\(UUID().uuidString)",
      "primary":{"id":"\(UUID().uuidString)","launchesClaudeCode":true},
      "splitDirection":{"horizontal":{}}}],"selectedTabID":"\(UUID().uuidString)"}
      """
    let data = try #require(json.data(using: .utf8))
    let layout = try JSONDecoder().decode(TerminalLayout.self, from: data)
    #expect(layout.tabs[0].focusedSurfaceID == nil)
    #expect(layout.tabs[0].focusedSurface.id == layout.tabs[0].primary.id)
  }
}
