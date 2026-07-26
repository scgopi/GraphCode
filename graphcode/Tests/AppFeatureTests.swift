import ComposableArchitecture
import Testing

@testable import graphcode

@Suite
struct AppFeatureTests {
  @Test
  @MainActor
  func creatingANodeShowsItsDetail() async {
    var initialState = AppFeature.State()
    initialState.draftTitle = "Test node"
    initialState.draftCheck = "Looks right?"

    let store = TestStore(initialState: initialState) {
      AppFeature()
    }
    store.exhaustivity = .off

    await store.send(.createNodeButtonTapped)

    #expect(store.state.detail?.node.title == "Test node")
    #expect(store.state.detail?.node.checkDescription == "Looks right?")
    #expect(store.state.detail?.node.loopType == .turnBased)
    #expect(store.state.detail?.node.backend == .claudeCode)
  }
}
