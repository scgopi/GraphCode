import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

@MainActor
@Suite
struct NodWorkspaceWiringTests {
  private final class TypedBox: @unchecked Sendable {
    var typed: [(UUID, String)] = []
  }

  private func workspace(backend: CLISessionBackendKind) -> LoopWorkspaceFeature.State {
    let node = LoopNode(
      title: "Monetization", loopType: .goalBased,
      goal: GoalSpec(summary: "every paid route enforces the cap"), backend: backend)
    return LoopWorkspaceFeature.State(
      node: node, layout: .defaultLayout(forNode: node.id), projectPath: "/tmp/project",
      projectName: "project")
  }

  @Test
  func onlyAChatLoopGetsAChat() async {
    let store = TestStore(initialState: workspace(backend: .claudeCode)) {
      LoopWorkspaceFeature()
    }
    await store.send(.chatSurfaceAppeared)

    let requests = LockIsolated<[String]>([])
    let nod = TestStore(initialState: workspace(backend: .nod)) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.orchestratorClient.send = { request in requests.withValue { $0.append("\(request)") } }
    }
    nod.exhaustivity = .off
    await nod.send(.chatSurfaceAppeared)
    await nod.finish()
    // No terminal attach starts a chat loop's session, so opening the pane asks for it.
    #expect(requests.value.count == 1)
    #expect(requests.value.first?.contains("resumeSession(\(nod.state.node.id))") == true)
    #expect(nod.state.nodChat?.goal == "every paid route enforces the cap")
    #expect(nod.state.nodChat?.loopType == .goalBased)
    #expect(nod.state.nodChat?.nodeID == nod.state.node.id)
  }

  @Test
  func theChatStartsOnTheModelSettingsWouldLaunch() async {
    var settings = NodSettings(engine: .copilotSDK)
    settings.editsInWorktree = .auto
    var pinned = workspace(backend: .nod)
    pinned.node.modelTier = .fast
    for (state, expected) in [
      (workspace(backend: .nod), "claude-opus-5.5"), (pinned, "gpt-5.6-luna"),
    ] {
      let store = TestStore(initialState: state) {
        LoopWorkspaceFeature()
      } withDependencies: {
        $0.nodSettings.current = { settings }
        $0.orchestratorClient.send = { _ in }
      }
      store.exhaustivity = .off
      await store.send(.chatSurfaceAppeared)
      #expect(store.state.nodChat?.model == expected)
      #expect(store.state.nodChat?.engine == .copilotSDK)
      #expect(store.state.nodChat?.editPolicy == .auto)
    }
    #expect(NodChatPresentation.modelLabel("gpt-6-sol", engine: .copilotSDK) == "GPT-6 Sol")
    #expect(
      NodChatPresentation.modelLabel("claude-sonnet-4-5", engine: .claudeAgentSDK) == "Sonnet")
    #expect(NodChatPresentation.modelLabel(nil, engine: .claudeAgentSDK) == "Model")
  }

  @Test
  func openInShellTabTypesIntoAPlainShellTabMakingOneIfNeeded() async {
    let box = TypedBox()
    let store = TestStore(initialState: workspace(backend: .nod)) {
      LoopWorkspaceFeature()
    } withDependencies: {
      $0.terminalLayoutStore = TerminalLayoutStore(
        baseDirectory: FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString))
      $0.terminalSurfaceClient.typeText = { id, text in box.typed.append((id, text)) }
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off
    await store.send(.chatSurfaceAppeared)
    let chatTab = store.state.layout.selectedTabID

    await store.send(.nodChat(.delegate(.openInShellTab(command: "swift test"))))
    #expect(store.state.layout.tabs.count == 2)
    let shellTab = store.state.layout.tabs[1]
    #expect(store.state.layout.selectedTabID == shellTab.id)
    #expect(!shellTab.primary.launchesClaudeCode)
    #expect(box.typed.map(\.0) == [shellTab.primary.id])
    #expect(box.typed.map(\.1) == ["swift test"])

    await store.send(.tabSelected(chatTab))
    await store.send(.nodChat(.delegate(.openInShellTab(command: "make lint"))))
    #expect(store.state.layout.tabs.count == 2)
    #expect(store.state.layout.selectedTabID == shellTab.id)
    #expect(box.typed.map(\.1) == ["swift test", "make lint"])
  }
}

@Suite
struct NodControlSocketTests {
  /// A one-shot runtime stand-in: accepts one connection, reads one line, answers `reply`.
  private func serve(reply: String) throws -> (path: String, received: () -> String) {
    let path = "/tmp/nod-\(UUID().uuidString.prefix(8)).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(bound == 0)
    listen(fd, 1)
    let lock = NSLock()
    nonisolated(unsafe) var received = ""
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let client = accept(fd, nil, nil)
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = read(client, &buffer, buffer.count)
      lock.lock()
      received = String(decoding: buffer[0..<max(count, 0)], as: UTF8.self)
      lock.unlock()
      let answer = Array((reply + "\n").utf8)
      _ = write(client, answer, answer.count)
      close(client)
      close(fd)
      unlink(path)
      done.signal()
    }
    return (
      path,
      {
        done.wait()
        lock.lock()
        defer { lock.unlock() }
        return received
      }
    )
  }

  @Test
  func aCommandIsOneLineAndOkIsSuccess() throws {
    let server = try serve(reply: "{\"ok\":true}")
    try NodControlSocket.send(.send(.init(text: "hi", delivery: .steer)), to: server.path)
    let line = server.received()
    #expect(line.hasSuffix("\n"))
    #expect(line.filter { $0 == "\n" }.count == 1)
    let decoded = try NodProtocol.makeDecoder().decode(NodCommand.self, from: Data(line.utf8))
    #expect(decoded == .send(.init(text: "hi", delivery: .steer)))
  }

  @Test
  func aRefusalCarriesTheRuntimesError() throws {
    let server = try serve(reply: "{\"ok\":false,\"error\":\"no such hunk\"}")
    #expect(throws: NodControlError.rejected("no such hunk")) {
      try NodControlSocket.send(.stop, to: server.path)
    }
    _ = server.received()
  }

  @Test
  func noRuntimeIsUnreachableNotAHang() {
    #expect(throws: NodControlError.self) {
      try NodControlSocket.send(.stop, to: "/tmp/nod-missing-\(UUID().uuidString.prefix(8)).sock")
    }
  }
}
