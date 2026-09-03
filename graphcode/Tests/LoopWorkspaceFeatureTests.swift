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
  /// Records what the reducer asks `TerminalSurfaceClient` to end: the attach going
  /// away (`retired`) and the zmx sessions being terminated behind it (`killed`).
  private final class EndingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var retiredIDs: [UUID] = []
    private var killedIDs: [UUID] = []

    func retire(_ ids: [UUID]) {
      lock.lock()
      retiredIDs += ids
      lock.unlock()
    }

    func kill(_ ids: [UUID]) {
      lock.lock()
      killedIDs += ids
      lock.unlock()
    }

    var retired: [UUID] {
      lock.lock()
      defer { lock.unlock() }
      return retiredIDs
    }

    var killed: [UUID] {
      lock.lock()
      defer { lock.unlock() }
      return killedIDs
    }
  }

  private func makeStore(
    _ state: LoopWorkspaceFeature.State,
    endings: EndingRecorder? = nil
  ) -> TestStoreOf<LoopWorkspaceFeature> {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-tests-\(UUID().uuidString)", isDirectory: true)
    let store = TestStore(initialState: state) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(baseDirectory: directory)
      $0.terminalSurfaceClient = TerminalSurfaceClient(
        retire: { endings?.retire($0) },
        retireAll: {},
        killSessions: { ids, _ in endings?.kill(ids) })
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

  /// Closing the last tab is the end of the loop itself — the reducer forwards to
  /// `AppFeature`, which asks the human before deleting anything (#254). Nothing is torn
  /// down on the way out: the layout still stands, its surfaces are still attached and
  /// its shells still running, because the answer may be no.
  @Test
  @MainActor
  func closingTheLastTabAsksItsParentToEndTheLoop() async {
    let endings = EndingRecorder()
    let store = makeStore(makeState(), endings: endings)
    let onlyTabID = store.state.layout.selectedTabID

    await store.send(.tabClosed(onlyTabID))
    await store.receive(\.lastTabClosed)
    #expect(store.state.layout.tabs.count == 1)
    #expect(endings.retired.isEmpty)
    #expect(endings.killed.isEmpty)
  }

  /// The same, for the shape that made this reachable without any click at all: a plain
  /// shell whose process exits sends `.paneClosed`, which collapses to `.tabClosed` when
  /// the shell is the tab's only pane. Typing `exit` must not be what deletes a loop —
  /// it asks, exactly like the x does, and kills nothing while the question is open.
  @Test
  @MainActor
  func aLoneShellExitingAsksRatherThanEndingTheLoopOutright() async {
    var state = makeState()
    let shell = SurfaceRef(id: UUID(), launchesClaudeCode: false)
    let shellTab = TabLayout(primary: shell)
    state.layout = TerminalLayout(tabs: [shellTab], selectedTabID: shellTab.id)

    let endings = EndingRecorder()
    let store = makeStore(state, endings: endings)
    await store.send(.paneClosed(tabID: shellTab.id, surfaceID: shell.id))

    await store.receive(\.tabClosed)
    await store.receive(\.lastTabClosed)
    #expect(endings.killed.isEmpty)
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

  /// A shell tab the human closed dies with it — its zmx session is killed, not just
  /// detached — while the loop's agent session in the surviving tab is untouched (#254).
  @Test
  @MainActor
  func closingAShellTabKillsItsSessionAndSparesTheAgent() async {
    var state = makeState()
    let shellTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    state.layout.tabs.append(shellTab)

    let endings = EndingRecorder()
    let store = makeStore(state, endings: endings)
    await store.send(.tabClosed(shellTab.id))

    #expect(endings.killed == [shellTab.primary.id])
    #expect(!endings.retired.isEmpty)
    #expect(!endings.killed.contains(state.node.id))
  }

  /// The other side of the same rule: closing the tab that carries the loop's own
  /// session retires its surface but never kills the session — the loop outlives any
  /// pane, and its session ends when the node does.
  @Test
  @MainActor
  func closingTheAgentTabNeverKillsTheAgentSession() async {
    var state = makeState()
    let shellTab = TabLayout(primary: SurfaceRef(id: UUID(), launchesClaudeCode: false))
    state.layout.tabs.append(shellTab)

    let endings = EndingRecorder()
    let store = makeStore(state, endings: endings)
    await store.send(.tabClosed(state.layout.tabs[0].id))

    #expect(endings.killed.isEmpty)
  }

  /// A shell pane closed out of a split ends its session (#254).
  @Test
  @MainActor
  func closingAShellPaneKillsItsSession() async throws {
    let endings = EndingRecorder()
    let store = makeStore(makeState(), endings: endings)
    let tabID = store.state.layout.selectedTabID
    await store.send(.splitButtonTapped(direction: .horizontal))
    let addition = try #require(store.state.layout.tabs[id: tabID]?.surfaces.last)

    await store.send(.paneClosed(tabID: tabID, surfaceID: addition.id))

    #expect(endings.killed == [addition.id])
  }

  /// And the agent pane of a split is spared, exactly like the agent tab is.
  @Test
  @MainActor
  func closingAnAgentPaneNeverKillsTheAgentSession() async throws {
    let endings = EndingRecorder()
    let store = makeStore(makeState(), endings: endings)
    let tabID = store.state.layout.selectedTabID
    await store.send(.splitButtonTapped(direction: .horizontal))
    let originalPrimary = try #require(store.state.layout.tabs[id: tabID]?.primary)

    await store.send(.paneClosed(tabID: tabID, surfaceID: originalPrimary.id))

    #expect(endings.killed.isEmpty)
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
