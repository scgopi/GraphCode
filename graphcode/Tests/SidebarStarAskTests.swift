import ComposableArchitecture
import Foundation
import Testing

@testable import graphcode

/// The star ask's reducer half: it stays silent until the threshold, a tap opens the
/// repository, and once answered it never shows again.
@Suite
struct SidebarStarAskTests {
  private actor OpenedURLsBox {
    private(set) var urls: [URL] = []
    func append(_ url: URL) { urls.append(url) }
  }

  private func state(count: Int, answered: Bool = false) -> AppFeature.State {
    let state = AppFeature.State()
    state.starAsk.$resolvedLoopCount.withLock { $0 = count }
    state.starAsk.$isAnswered.withLock { $0 = answered }
    return state
  }

  @Test
  func theAskStaysHiddenUntilThreeLoopsHaveResolved() {
    #expect(!state(count: StarAsk.threshold - 1).starAsk.isEarned)
    #expect(state(count: StarAsk.threshold).starAsk.isEarned)
  }

  @Test
  func anAnswerRetiresTheAskForGood() {
    #expect(!state(count: StarAsk.threshold + 9, answered: true).starAsk.isEarned)
  }

  @Test
  @MainActor
  func tappingTheBannerOpensTheRepositoryAndAnswersIt() async {
    let opened = OpenedURLsBox()
    let store = TestStore(initialState: state(count: StarAsk.threshold)) {
      AppFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        await opened.append(url)
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.starAsk(.tapped)) { $0.starAsk.$isAnswered.withLock { $0 = true } }
    await store.finish()

    #expect(await opened.urls == [StarAsk.repositoryURL])
    #expect(!store.state.starAsk.isEarned)
  }

  @Test
  @MainActor
  func dismissingTheBannerAnswersItWithoutOpeningTheRepository() async {
    let opened = OpenedURLsBox()
    let store = TestStore(initialState: state(count: StarAsk.threshold)) {
      AppFeature()
    } withDependencies: {
      $0.openURL = OpenURLEffect { url in
        await opened.append(url)
        return true
      }
    }
    store.exhaustivity = .off

    await store.send(.starAsk(.dismissed)) { $0.starAsk.$isAnswered.withLock { $0 = true } }
    await store.finish()

    #expect(await opened.urls.isEmpty)
    #expect(!store.state.starAsk.isEarned)
  }
}
