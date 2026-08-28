import ComposableArchitecture
import Foundation

/// The one-time ask to star the project on GitHub.
///
/// The install path routes around github.com entirely — `brew install --cask` puts the
/// app on disk without the user ever seeing the repository — so every surface that asks
/// (README, site) reaches only the people who already found it. This is the ask aimed at
/// the population that actually installs.
///
/// It is *earned*: nothing appears until three loops have resolved on this machine, so
/// the first time the app asks for anything it has already done the thing it claims to
/// do. It is shown once, it never returns once answered, and it yields to the update
/// banner — news the user asked for outranks an ask aimed at them.
struct StarAskState: Equatable {
  @Shared(.appStorage(StarAsk.resolvedCountKey)) var resolvedLoopCount = 0
  @Shared(.appStorage(StarAsk.answeredKey)) var isAnswered = false

  /// Shown only past the threshold, only once, and only while the ramp allows it.
  var isEarned: Bool {
    !isAnswered && resolvedLoopCount >= StarAsk.threshold && FeatureRamps.isEnabled(.starAsk)
  }
}

enum StarAsk {
  static let threshold = 3
  static let resolvedCountKey = "starAskResolvedLoopCount"
  static let answeredKey = "starAskAnswered"
  static let repositoryURL = URL(string: "https://github.com/scgopi/GraphCode")!

  @CasePathable
  enum Action: Equatable {
    /// A tap is an answer either way: the star itself happens on a page this app cannot
    /// see, so asking again after sending someone there would be asking twice.
    case tapped
    case dismissed
  }
}

/// Counts resolutions and answers the banner's two actions. Placed before the main
/// `Reduce` for the same reason `AppWorktreesReducer` is: the count comes from diffing
/// the incoming graph against the previous one, which the main reducer replaces.
struct StarAskReducer: Reducer {
  typealias State = AppFeature.State
  typealias Action = AppFeature.Action

  @Dependency(\.openURL) var openURL

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .daemonEvent(.graphChanged(let graph)):
        guard !state.starAsk.isAnswered else { return .none }
        // Crossings only. Counting resolved nodes outright would re-count the same loop
        // on every broadcast and reach the threshold on the first graph that has one.
        let previous = state.projects[id: graph.project.path]?.graph
        let resolutions = graph.nodes.filter { node in
          node.isResolved && previous?.nodes[id: node.id].map { !$0.isResolved } == true
        }.count
        guard resolutions > 0 else { return .none }
        state.starAsk.$resolvedLoopCount.withLock { $0 += resolutions }
        return .none

      case .starAsk(.tapped):
        state.starAsk.$isAnswered.withLock { $0 = true }
        return .run { [openURL] _ in await openURL(StarAsk.repositoryURL) }

      case .starAsk(.dismissed):
        state.starAsk.$isAnswered.withLock { $0 = true }
        return .none

      default:
        return .none
      }
    }
  }
}
