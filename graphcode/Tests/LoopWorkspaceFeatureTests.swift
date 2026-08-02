import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// `LoopWorkspaceFeature` owns one loop's tabs + simple 2-pane splits
/// (docs/07-roadmap.md's per-loop terminal workspace follow-up). Every mutation
/// persists via `TerminalLayoutStore`, so these also incidentally cover that the right
/// save happens at the right time — a temp-directory-backed store is injected so tests
/// never touch the app's real Application Support folder.
@Suite
struct LoopWorkspaceFeatureTests {
  private func makeStore(_ state: LoopWorkspaceFeature.State) -> TestStoreOf<LoopWorkspaceFeature> {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let store = TestStore(initialState: state) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
    }
    store.exhaustivity = .off
    return store
  }

  private func makeState() -> LoopWorkspaceFeature.State {
    let node = LoopNode(title: "Research", checkDescription: "Sound?")
    return LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: "/tmp/project-a",
      projectName: "project-a")
  }

  @Test
  @MainActor
  func newTabButtonAddsAPlainShellTabAndSelectsIt() async {
    let store = makeStore(makeState())
    let originalTabID = store.state.layout.selectedTabID

    await store.send(.newTabButtonTapped)

    #expect(store.state.layout.tabs.count == 2)
    #expect(store.state.layout.selectedTabID != originalTabID)
    let newTab = store.state.layout.tabs[id: store.state.layout.selectedTabID]
    #expect(newTab?.primary.launchesClaudeCode == false)
  }

  /// Issue #11: ⌘D used to add a pane once per tab and then do nothing at all.
  @Test
  @MainActor
  func splitButtonAddsAPaneEveryTimeItIsPressed() async {
    let store = makeStore(makeState())
    let tabID = store.state.layout.selectedTabID

    await store.send(.splitButtonTapped(direction: .horizontal))
    #expect(store.state.layout.tabs[id: tabID]?.surfaces.count == 2)

    await store.send(.splitButtonTapped(direction: .horizontal))
    #expect(store.state.layout.tabs[id: tabID]?.surfaces.count == 3)

    await store.send(.splitButtonTapped(direction: .horizontal))
    #expect(store.state.layout.tabs[id: tabID]?.surfaces.count == 4)

    // Four panes on one axis, not a stack of nested halves — repeated ⌘D divides the row
    // it already made rather than subdividing the pane it just added.
    guard case .split(let direction, let children) = store.state.layout.tabs[id: tabID]?.root
    else { return #expect(Bool(false), "the tab should be split") }
    #expect(direction == .horizontal)
    #expect(children.count == 4)
    #expect(children.allSatisfy { !$0.isSplit })
  }

  /// The other axis nests, because it has to: a column inside one pane of a row is the
  /// only thing "split this pane downward" can mean.
  @Test
  @MainActor
  func splittingTheOtherWayNestsInsideTheFocusedPane() async throws {
    let store = makeStore(makeState())
    let tabID = store.state.layout.selectedTabID

    await store.send(.splitButtonTapped(direction: .horizontal))
    await store.send(.splitButtonTapped(direction: .vertical))

    let tab = try #require(store.state.layout.tabs[id: tabID])
    #expect(tab.surfaces.count == 3)
    guard case .split(let direction, let children) = tab.root
    else { return #expect(Bool(false), "the tab should be split") }
    #expect(direction == .horizontal)
    #expect(children.count == 2)
    // The second pane — the one ⌘D made and left focused — is what ⌘⇧D divided.
    #expect(children[0].isSplit == false)
    #expect(children[1].isSplit)
  }

  @Test
  @MainActor
  func closingTheLastTabIsANoOp() async {
    let store = makeStore(makeState())
    let onlyTabID = store.state.layout.selectedTabID

    await store.send(.tabClosed(onlyTabID))
    #expect(store.state.layout.tabs.count == 1)
  }

  @Test
  @MainActor
  func closingATabFallsBackToAnAdjacentOne() async {
    var state = makeState()
    let firstTabID = state.layout.tabs[0].id
    let secondTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    state.layout.tabs.append(secondTab)
    state.layout.selectedTabID = secondTab.id

    let store = makeStore(state)
    await store.send(.tabClosed(secondTab.id))

    #expect(store.state.layout.tabs.count == 1)
    #expect(store.state.layout.selectedTabID == firstTabID)
  }

  @Test
  @MainActor
  func selectNextAndPreviousTabStepThroughAndWrap() async {
    var state = makeState()
    let firstTabID = state.layout.tabs[0].id
    let secondTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    let thirdTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    state.layout.tabs.append(contentsOf: [secondTab, thirdTab])

    let store = makeStore(state)

    await store.send(.selectNextTab)
    #expect(store.state.layout.selectedTabID == secondTab.id)

    await store.send(.selectNextTab)
    #expect(store.state.layout.selectedTabID == thirdTab.id)

    // Past the last tab wraps back to the first.
    await store.send(.selectNextTab)
    #expect(store.state.layout.selectedTabID == firstTabID)

    // And back the other way wraps to the last.
    await store.send(.selectPreviousTab)
    #expect(store.state.layout.selectedTabID == thirdTab.id)
  }

  @Test
  @MainActor
  func closingOnePaneOfASplitCollapsesToTheOtherSurface() async throws {
    let store = makeStore(makeState())
    let tabID = store.state.layout.selectedTabID
    let originalPrimary = try #require(store.state.layout.tabs[id: tabID]?.primary)

    await store.send(.splitButtonTapped(direction: .horizontal))
    let addition = try #require(store.state.layout.tabs[id: tabID]?.surfaces.last)

    await store.send(.paneClosed(tabID: tabID, surfaceID: originalPrimary.id))

    let tab = store.state.layout.tabs[id: tabID]
    #expect(tab?.isSplit == false)
    #expect(tab?.primary.id == addition.id)
  }

  /// Closing a pane out of three leaves a split of two, not a tab with a stray empty slot
  /// in it — and the two that stay are the same live terminals they were.
  @Test
  @MainActor
  func closingOnePaneOfThreeLeavesTheOtherTwoSplit() async throws {
    let store = makeStore(makeState())
    let tabID = store.state.layout.selectedTabID

    await store.send(.splitButtonTapped(direction: .horizontal))
    await store.send(.splitButtonTapped(direction: .horizontal))
    let panes = try #require(store.state.layout.tabs[id: tabID]?.surfaces)
    #expect(panes.count == 3)

    await store.send(.paneClosed(tabID: tabID, surfaceID: panes[1].id))

    let tab = try #require(store.state.layout.tabs[id: tabID])
    #expect(tab.isSplit)
    #expect(tab.surfaces.map(\.id) == [panes[0].id, panes[2].id])
  }

  @Test
  @MainActor
  func closingAnUnsplitPaneClosesItsTab() async {
    var state = makeState()
    let secondTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    state.layout.tabs.append(secondTab)
    state.layout.selectedTabID = secondTab.id

    let store = makeStore(state)
    await store.send(.paneClosed(tabID: secondTab.id, surfaceID: secondTab.primary.id))
    // An unsplit pane's close is forwarded via a `.send(.tabClosed(...))` effect —
    // drain it before asserting.
    await store.receive(\.tabClosed)

    #expect(store.state.layout.tabs.count == 1)
  }

  @Test
  @MainActor
  func primarySurfaceExitedUpdatesNodeState() async {
    let store = makeStore(makeState())

    await store.send(.primarySurfaceExited(succeeded: true))
    #expect(store.state.node.state == .succeeded)

    await store.send(.primarySurfaceExited(succeeded: false))
    #expect(store.state.node.state == .failed)
  }

  @Test
  @MainActor
  func mutationsArePersisted() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
    let state = makeState()

    let store = TestStore(initialState: state) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = terminalLayoutStore
    }
    store.exhaustivity = .off

    await store.send(.newTabButtonTapped)

    #expect(terminalLayoutStore.load(forNode: state.node.id)?.tabs.count == 2)
  }

  @Test
  func theRailIsSilentAboutALoopWiredToNothing() {
    // What prompted this: a workspace opened with 212 points of panel beside its
    // terminal saying nothing — a caption, a rect between two dashes, and a date. 15% of
    // the window, taken from the pane someone is actually working in.
    let alone = LoopNode(title: "alone")
    let graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [alone])

    #expect(!LoopWorkspaceRail.hasContent(node: alone, graph: graph))
    #expect(LoopWorkspaceRail.downstreamCount(node: alone, graph: graph) == 0)
  }

  @Test
  func anEdgeInEitherDirectionIsWorthTheRail() {
    // Downstream is the obvious case; upstream matters too, because the minimap is how
    // you see what feeds this loop without leaving the terminal.
    let first = LoopNode(title: "first")
    let second = LoopNode(title: "second")
    let graph = LoopGraph(
      project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [first, second],
      edges: [LoopEdge(from: first.id, to: second.id)])

    #expect(LoopWorkspaceRail.hasContent(node: first, graph: graph))
    #expect(LoopWorkspaceRail.hasContent(node: second, graph: graph))
    #expect(LoopWorkspaceRail.downstreamCount(node: first, graph: graph) == 1)
    #expect(LoopWorkspaceRail.downstreamCount(node: second, graph: graph) == 0)
  }

  @Test
  func aMetricEarnsTheRailOnItsOwn() {
    // A goal loop with a trend has something to show even with nothing wired to it —
    // the sparkline is the one part of the rail that needs no edges at all.
    let measured = LoopNode(
      title: "measured",
      metricHistory: [MetricSample(value: 1), MetricSample(value: 2)])
    let graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [measured])

    #expect(LoopWorkspaceRail.hasContent(node: measured, graph: graph))
    // One sample is not a trend, and the sparkline refuses to draw it.
    var single = measured
    single.metricHistory = [MetricSample(value: 1)]
    #expect(!LoopWorkspaceRail.hasContent(node: single, graph: graph))
  }

  @Test
  func aLoopWithNoPanelGetsNoToggleAtAll() {
    // It was shown greyed for a while, on the argument that a visibly-unavailable
    // control answers "where did the panel go". In use it read as broken instead: a
    // permanently dim button whose reason lives in a tooltip nobody hovers is a question
    // mark in the toolbar. `hasContent` is what the toolbar item is now gated on, so a
    // loop wired to nothing shows no button — and gets one the moment it is wired.
    let alone = LoopNode(title: "alone")
    let graph = LoopGraph(project: ProjectRef(path: "/tmp/p", name: "p"), nodes: [alone])

    #expect(!LoopWorkspaceRail.hasContent(node: alone, graph: graph))
  }

  @Test
  func togglingTheRailPersistsThroughTheReducer() async {
    // The toggle lives in the window toolbar, which `AppView` owns, and the panel lives
    // in the workspace — a control and the thing it controls cannot hold the answer
    // separately, so the state moved into the store.
    let key = LoopWorkspaceRail.visibleDefaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    UserDefaults.standard.set(false, forKey: key)

    let store = TestStore(
      initialState: LoopWorkspaceFeature.State(
        node: LoopNode(title: "a"), layout: .defaultLayout(forNode: UUID()),
        projectPath: "/tmp/p", projectName: "p")
    ) { LoopWorkspaceFeature() }
    store.exhaustivity = .off

    await store.send(.railToggled) { $0.isRailVisible = true }
    #expect(LoopWorkspaceRail.loadVisible())
  }

  @Test
  func theRailStartsHiddenUntilSomebodyAsksForIt() {
    // Defaulting it on is what put an empty panel in front of every loop that feeds
    // nothing. Turning it on persists, so wiring a graph costs the toggle once.
    let key = LoopWorkspaceRail.visibleDefaultsKey
    let saved = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.removeObject(forKey: key)
    defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } }

    #expect(LoopWorkspaceRail.loadVisible() == false)
  }
}
