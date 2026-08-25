import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// ⌘` and ⌘⇧` — stepping to the next workspace rather than naming one with ⌥⌘<n>.
///
/// Issue #175. The list these walk is `Workspace.all()`, which is in creation order; what
/// is pinned here is the walking itself — that it wraps at both ends, that it re-reads the
/// list rather than trusting whatever the last menu opening left in state, and that a
/// machine with one workspace gets nothing rather than a switch to itself.
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

  @MainActor
  private func store(
    current: Workspace, list: [Workspace], opened: LockIsolated<[Workspace]>
  ) -> TestStoreOf<AppFeature> {
    let store = TestStore(initialState: state(current: current)) {
      AppFeature()
    } withDependencies: {
      $0.workspaceClient.list = { list }
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
}
