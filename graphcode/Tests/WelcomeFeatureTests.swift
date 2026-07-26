import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Phase 4's welcome screen (docs/07-roadmap.md#phase-4--projects) — covers that both
/// ways of choosing a project (a recent-projects row, or the folder picker) send
/// `.openProject` with the right path.
@Suite
struct WelcomeFeatureTests {
  @Test
  @MainActor
  func tappingARecentProjectSendsOpenProject() async {
    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    let project = ProjectRef(path: "/tmp/some-project", name: "some-project")
    await store.send(.recentProjectTapped(project))

    let commands = await sentCommands.all
    #expect(commands == [.openProject(path: project.path)])
  }

  @Test
  @MainActor
  func pickingAFolderSendsOpenProject() async {
    let sentCommands = SentCommandsBox()
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sentCommands.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.folderPickerResult(.success(URL(fileURLWithPath: "/tmp/picked-folder"))))

    let commands = await sentCommands.all
    #expect(commands == [.openProject(path: "/tmp/picked-folder")])
  }

  @Test
  @MainActor
  func aFailedFolderPickShowsAnErrorInstead() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    }
    store.exhaustivity = .off

    struct PickFailed: Error {}
    await store.send(.folderPickerResult(.failure(PickFailed())))
    #expect(store.state.errorMessage != nil)
  }
}

private actor SentCommandsBox {
  private(set) var all: [DaemonCommand] = []
  func append(_ command: DaemonCommand) { all.append(command) }
}
