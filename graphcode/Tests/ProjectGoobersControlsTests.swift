import ComposableArchitecture
import GraphcodeKit
import Testing

@testable import graphcode

@Suite
struct ProjectGoobersControlsTests {
  @Test
  @MainActor
  func controlsSendWholeGraphCommands() async {
    let project = ProjectRef(path: "/tmp/test-project", name: "test-project")
    let sent = SentGraphCommandsBox()
    let store = TestStore(
      initialState: ProjectFeature.State(graph: LoopGraph(project: project))
    ) {
      ProjectFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { command in await sent.append(command) }
    }
    store.exhaustivity = .off

    await store.send(.executionModeChanged(.goobers))
    await store.send(.runGoobersTapped)
    await store.finish()

    #expect(
      await sent.commands == [
        .graphCommand(
          projectPath: project.path, command: .setExecutionMode(.goobers)),
        .graphCommand(projectPath: project.path, command: .runGoobers),
      ])
  }
}
