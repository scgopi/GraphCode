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
}
