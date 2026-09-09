import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// ⌘` and ⌘⇧` — stepping to the next workspace rather than naming one with ⌥⌘<n>.
///
/// Issue #175. The list these walk is `Workspace.all()`, which is in creation order,
/// narrowed to the workspaces that have a window (issue #330 — the ones the update path's
/// `otherOpen` reports, plus this one). What is pinned here is the walking itself — that
/// it wraps at both ends, that it re-reads the list rather than trusting whatever the last
/// menu opening left in state, that a machine with one workspace gets nothing rather than
/// a switch to itself, and that a workspace someone quit stays quit.
@Suite
struct WorkspaceCycleTests {
  private func workspace(_ slug: String) -> Workspace {
    Workspace(slug: slug, url: URL(fileURLWithPath: "/tmp/.graphcode-\(slug)"))
  }

  private func state(current: Workspace) -> AppFeature.State {
    var state = AppFeature.State()
    state.workspaces.current = current
    return state
  }

  /// `list` is what is on disk; `running` is which of the *others* have an instance —
  /// `nil` means all of them, the pre-#330 world where the two were never told apart.
  @MainActor
  private func store(
    current: Workspace, list: [Workspace], running: [Workspace]? = nil,
    opened: LockIsolated<[Workspace]>
  ) -> TestStoreOf<AppFeature> {
    let others = running ?? list.filter { $0.id != current.id }
    let store = TestStore(initialState: state(current: current)) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.list = { list }
      $0.workspaceClient.otherOpen = { others }
      $0.workspaceClient.open = { workspace in opened.withValue { $0.append(workspace) } }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  @MainActor
  func nextGoesOnePlaceDownTheList() async {
    let work = workspace("work")
    let oss = workspace("oss")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(current: work, list: [.default, work, oss], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [oss])
  }

  @Test
  @MainActor
  func nextWrapsRoundFromTheLastToTheFirst() async {
    let work = workspace("work")
    let oss = workspace("oss")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(current: oss, list: [.default, work, oss], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [.default])
  }

  @Test
  @MainActor
  func previousWrapsRoundFromTheFirstToTheLast() async {
    // `%` keeps a negative dividend negative in Swift, so this is the case that indexes
    // -1 if the modulo is written the obvious way.
    let work = workspace("work")
    let oss = workspace("oss")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(current: .default, list: [.default, work, oss], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: -1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [oss])
  }

  @Test
  @MainActor
  func oneWorkspaceHasNowhereToGo() async {
    let opened = LockIsolated<[Workspace]>([])
    let store = store(current: .default, list: [.default], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))

    #expect(opened.value.isEmpty)
  }

  @Test
  @MainActor
  func theListIsReReadRatherThanTakenFromState() async {
    // A keystroke, not a menu opening: nothing has necessarily refreshed `known` since
    // launch, and a workspace another instance created since then is one ⌘` must not
    // skip over.
    let work = workspace("work")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(current: .default, list: [.default, work], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [work])
    #expect(store.state.workspaces.known == [.default, work])
  }

  // MARK: - Issue #330: only running workspaces are cycled

  @Test
  @MainActor
  func aWorkspaceWithNoWindowIsSteppedOver() async {
    // `work` is on disk and next in creation order, but nobody has it open. ⌘` must land
    // on `oss` — going to `work` would mean launching it, which is the bug.
    let work = workspace("work")
    let oss = workspace("oss")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(
      current: .default, list: [.default, work, oss], running: [oss], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [oss])
  }

  @Test
  @MainActor
  func nothingElseRunningMeansNowhereToGo() async {
    // The other workspaces exist, and every one of them was quit. ⌘` does nothing rather
    // than resurrecting the first of them.
    let work = workspace("work")
    let oss = workspace("oss")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(
      current: .default, list: [.default, work, oss], running: [], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.send(.workspaces(.cycleRequested(offset: -1)))

    #expect(opened.value.isEmpty)
  }

  @Test
  @MainActor
  func wrappingCountsTheRunningOnesNotTheOnesOnDisk() async {
    // Four on disk, two of them dead: from the last running one, ⌘` wraps to the first
    // running one, and ⌘⇧` from there comes straight back. An index taken from the disk
    // list with a modulus of the running count — or the other way round — lands on a dead
    // workspace or off the end.
    let work = workspace("work")
    let oss = workspace("oss")
    let home = workspace("home")
    let opened = LockIsolated<[Workspace]>([])
    let store = store(
      current: home, list: [.default, work, oss, home], running: [work], opened: opened)

    await store.send(.workspaces(.cycleRequested(offset: 1)))
    await store.receive(\.workspaces.switchRequested)
    await store.send(.workspaces(.cycleRequested(offset: -1)))
    await store.receive(\.workspaces.switchRequested)

    #expect(opened.value == [work, work])
  }
}
