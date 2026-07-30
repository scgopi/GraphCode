import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Repositories on remote machines over SSH (docs/09-remote-repositories.md Phase B):
/// the `ssh://` project identity, the quoting every remote command survives on, the
/// launch/attach invocations built from them, and the add form's validate-then-open
/// flow. The daemon stays local — every assertion here is about the argv it builds,
/// which is the entire remote surface.
@Suite
struct RemoteRepositoryTests {
  private let location = RemoteProjectLocation(
    user: "dev", host: "build-box", port: 2222, remotePath: "/home/dev/widget")

  // MARK: - Identity

  @Test
  func theProjectPathRoundTripsThroughParse() {
    let path = location.projectPath
    #expect(path == "ssh://dev@build-box:2222/home/dev/widget")
    #expect(RemoteProjectLocation.parse(projectPath: path) == location)
  }

  @Test
  func onlyRealRemotePathsParse() {
    // Local folders, the global graph, and junk all take the local branch.
    #expect(RemoteProjectLocation.parse(projectPath: "/Users/dev/widget") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: LoopGraphScope.globalPath) == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "ssh://") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "ssh://host") == nil)
    // Minimal form: host and absolute path, no user or port.
    let bare = RemoteProjectLocation.parse(projectPath: "ssh://host/srv/repo")
    #expect(bare == RemoteProjectLocation(host: "host", remotePath: "/srv/repo"))
  }

  @Test
  func theDisplayNameCarriesTheHost() {
    // Two checkouts of the same repo — one local, one remote — must be tellable apart
    // in the sidebar.
    #expect(location.displayName == "widget @ build-box")
  }

  // MARK: - Quoting

  @Test
  func hostileTextSurvivesShellQuoting() {
    let hostile = "a'; rm -rf ~; echo '$(whoami)`id`"
    let quoted = RemoteProjectLocation.shellQuoted(hostile)
    // Single-quote escaping: the only unquoted characters are the escape sequence
    // itself, so nothing inside can become syntax.
    #expect(quoted == "'a'\\''; rm -rf ~; echo '\\''$(whoami)`id`'")
  }

  @Test
  func sshInvocationsFailFastAndCarryThePort() {
    let invocation = location.sshInvocation(remoteCommand: "true")
    #expect(invocation.first == "/usr/bin/ssh")
    #expect(!invocation.contains("-t"))
    #expect(invocation.contains("BatchMode=yes"))
    // The command is the final argument, after `--` and the destination.
    #expect(invocation.last == "true")
    #expect(invocation[invocation.count - 2] == "--")
    #expect(invocation.contains("dev@build-box"))
    #expect(invocation.contains("2222"))

    // Interactive (a terminal surface) allocates a tty; queries must not.
    #expect(location.sshInvocation(remoteCommand: "x", interactive: true).contains("-t"))
  }

  // MARK: - App attach

  private func surface(launchesClaudeCode: Bool, prompt: String?) -> GhosttyTerminalView {
    GhosttyTerminalView(
      surfaceID: UUID(), sessionName: "graphcode-s", launchesClaudeCode: launchesClaudeCode,
      initialPrompt: prompt, workingDirectory: location.projectPath,
      projectPath: location.projectPath, onProcessExited: { _ in })
  }

  @Test
  func anAgentSurfaceAttachesOverSSHWithThePromptEmbedded() throws {
    let view = surface(launchesClaudeCode: true, prompt: "fix the build")
    let invocation = view.remoteCommand(at: location, settings: GraphcodeSettings())

    #expect(invocation.first == "/usr/bin/ssh")
    // A terminal needs the remote side to have a tty.
    #expect(invocation.contains("-t"))
    let remoteCommand = try #require(invocation.last)
    #expect(remoteCommand.contains("cd "))
    #expect(remoteCommand.contains("/home/dev/widget"))
    // The prompt can't ride the local environment through sshd, so it is assigned
    // remotely — quoted, and expanded by the same "$GRAPHCODE_TRIGGER_PROMPT" the
    // local launch path uses.
    #expect(remoteCommand.contains("export GRAPHCODE_TRIGGER_PROMPT="))
    #expect(remoteCommand.contains("fix the build"))
    #expect(remoteCommand.contains("attach"))
    #expect(remoteCommand.contains("graphcode-s"))
    #expect(remoteCommand.contains("claude"))
  }

  @Test
  func aPlainShellTabOpensARemoteShellInTheRepository() throws {
    let view = surface(launchesClaudeCode: false, prompt: nil)
    let invocation = view.remoteCommand(at: location, settings: GraphcodeSettings())
    let remoteCommand = try #require(invocation.last)
    // `zmx attach <name>` with no command — a login shell on the remote host, in the
    // repository, exactly what a remote project's extra tab should be.
    #expect(remoteCommand.contains("cd "))
    #expect(remoteCommand.contains("/home/dev/widget"))
    #expect(remoteCommand.contains("attach"))
    #expect(remoteCommand.contains("graphcode-s"))
    #expect(!remoteCommand.contains("claude"))
  }

  @Test
  func aRemoteSurfaceGetsNoLocalWorkingDirectoryOrBriefing() {
    let view = surface(launchesClaudeCode: true, prompt: "go")
    // The ssh:// path names no local folder; handing it to Ghostty would fail the
    // spawn. The cd happens inside the remote command instead.
    #expect(view.effectiveWorkingDirectory == nil)
    #expect(view.briefingFile(settings: GraphcodeSettings()) == nil)
  }

  // MARK: - The add form

  @Test
  func theDraftRequiresAHostAndAnAbsolutePath() {
    var draft = WelcomeFeature.RemoteDraft()
    #expect(!draft.canSubmit)
    draft.server = "build-box"
    draft.remotePath = "~/widget"
    // `~` means nothing until the remote shell expands it; identity can't be ambiguous.
    #expect(draft.location == nil)
    draft.remotePath = "/home/dev/widget"
    #expect(draft.canSubmit)
    draft.port = "not-a-port"
    #expect(draft.location == nil)
  }

  @Test
  @MainActor
  func aValidatedConnectionOpensTheRemoteProject() async {
    let opened = OpenedRemoteProjectsBox()
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.remoteRepositoryClient.validate = { _ in nil }
      $0.orchestratorClient.send = { command in
        if case .openProject(let path) = command { await opened.append(path) }
      }
    }
    store.exhaustivity = .off

    await store.send(.addRemoteRepositoryButtonTapped)
    var draft = store.state.remoteDraft ?? WelcomeFeature.RemoteDraft()
    draft.server = "build-box"
    draft.user = "dev"
    draft.remotePath = "/home/dev/widget"
    await store.send(.binding(.set(\.remoteDraft, draft)))
    await store.send(.remoteSubmitted)
    await store.receive(\.remoteValidated)
    await store.finish()

    #expect(store.state.remoteDraft == nil)
    #expect(await opened.paths == ["ssh://dev@build-box/home/dev/widget"])
  }

  @Test
  @MainActor
  func aFailedValidationKeepsTheSheetOpenWithTheReason() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.remoteRepositoryClient.validate = { _ in "zmx isn't installed on build-box" }
      $0.orchestratorClient.send = { _ in }
    }
    store.exhaustivity = .off

    await store.send(.addRemoteRepositoryButtonTapped)
    var draft = store.state.remoteDraft ?? WelcomeFeature.RemoteDraft()
    draft.server = "build-box"
    draft.remotePath = "/srv/repo"
    await store.send(.binding(.set(\.remoteDraft, draft)))
    await store.send(.remoteSubmitted)
    await store.receive(\.remoteValidationFailed)
    await store.finish()

    #expect(store.state.remoteDraft?.isValidating == false)
    #expect(store.state.remoteDraft?.failureMessage?.contains("zmx") == true)
  }
}

private actor OpenedRemoteProjectsBox {
  var paths: [String] = []
  func append(_ path: String) { paths.append(path) }
}
