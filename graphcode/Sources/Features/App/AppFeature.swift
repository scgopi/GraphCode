import ComposableArchitecture
import Foundation

/// Root feature. Phase 1 scope (docs/07-roadmap.md): a single `LoopNode`, created
/// once from a small form, then handed off to `LoopNodeDetailFeature`. No
/// `LoopGraph`/canvas yet — that's Phase 2.
@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    var detail: LoopNodeDetailFeature.State?
    var draftTitle = "My first loop"
    var draftCheck = "Does this look right?"
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case createNodeButtonTapped
    case detail(LoopNodeDetailFeature.Action)
  }

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .createNodeButtonTapped:
        guard !state.draftTitle.isEmpty, !state.draftCheck.isEmpty else { return .none }
        let node = LoopNode(title: state.draftTitle, checkDescription: state.draftCheck)
        state.detail = LoopNodeDetailFeature.State(node: node)
        return .none

      case .detail:
        return .none
      }
    }
    .ifLet(\.detail, action: \.detail) {
      LoopNodeDetailFeature()
    }
  }
}
