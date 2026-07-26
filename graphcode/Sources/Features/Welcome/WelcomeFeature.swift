import ComposableArchitecture
import Foundation
import GraphcodeKit

/// The screen shown when no project is open (Phase 4,
/// docs/07-roadmap.md#phase-4--projects) — before this phase graphcode booted straight
/// into a single hardcoded graph with no notion of "open a folder" at all. Sends
/// `.openProject`/`.listRecentProjects` directly, the same way every other feature in
/// this codebase owns its own `orchestratorClient` calls rather than routing every
/// command through a central dispatcher; `AppFeature` only owns the one long-lived
/// event *subscription*, not the sending side.
@Reducer
struct WelcomeFeature {
  @ObservableState
  struct State: Equatable {
    var recentProjects: [ProjectRef] = []
    var isOpenPanelPresented = false
    var errorMessage: String?
  }

  enum Action {
    case openFolderButtonTapped
    case folderPickerResult(Result<URL, any Error>)
    case recentProjectTapped(ProjectRef)
    case setOpenPanelPresented(Bool)
  }

  @Dependency(\.orchestratorClient) var orchestratorClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .openFolderButtonTapped:
        state.isOpenPanelPresented = true
        return .none

      case .setOpenPanelPresented(let isPresented):
        state.isOpenPanelPresented = isPresented
        return .none

      case .folderPickerResult(.success(let url)):
        let path = url.path
        return .run { _ in try? await orchestratorClient.send(.openProject(path: path)) }

      case .folderPickerResult(.failure):
        state.errorMessage = "Couldn't read the selected folder."
        return .none

      case .recentProjectTapped(let project):
        return .run { _ in try? await orchestratorClient.send(.openProject(path: project.path)) }
      }
    }
  }
}
