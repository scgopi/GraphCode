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
    // Keepalives on every connection: without them a dead link is only discovered at
    // the OS TCP timeout, which reads as a frozen terminal (~15s bound here).
    #expect(invocation.contains("ServerAliveInterval=5"))
    #expect(invocation.contains("ServerAliveCountMax=3"))
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

    // The surface is a local /bin/sh reconnect loop around the ssh dial, so a dropped
    // connection redials itself instead of dying with the pane.
    #expect(invocation.first == "/bin/sh")
    #expect(invocation.dropFirst().first == "-c")
    let script = try #require(invocation.last)
    #expect(script.contains("/usr/bin/ssh"))
    // A terminal needs the remote side to have a tty.
    #expect(script.contains("'-t'"))
    #expect(script.contains("cd "))
    #expect(script.contains("/home/dev/widget"))
    // The prompt can't ride the local environment through sshd, so it is assigned
    // remotely — quoted, and expanded by the same "$GRAPHCODE_TRIGGER_PROMPT" the
    // local launch path uses.
    #expect(script.contains("export GRAPHCODE_TRIGGER_PROMPT="))
    #expect(script.contains("fix the build"))
    #expect(script.contains("attach"))
    #expect(script.contains("graphcode-s"))
    #expect(script.contains("claude"))
  }

  @Test
  func aPlainShellTabOpensARemoteShellInTheRepository() throws {
    let view = surface(launchesClaudeCode: false, prompt: nil)
    let invocation = view.remoteCommand(at: location, settings: GraphcodeSettings())
    #expect(invocation.first == "/bin/sh")
    let script = try #require(invocation.last)
    // `zmx attach <name>` with no command — a login shell on the remote host, in the
    // repository, exactly what a remote project's extra tab should be.
    #expect(script.contains("cd "))
    #expect(script.contains("/home/dev/widget"))
    #expect(script.contains("attach"))
    #expect(script.contains("graphcode-s"))
    #expect(!script.contains("claude"))
  }

  // MARK: - Reconnect

  @Test
  func theReconnectLoopRetriesOnlySSHConnectionFailures() {
    let script = SSHReconnectLoop.script(connect: "DIAL_FIRST", reconnect: "DIAL_AGAIN")
    // ssh reserves 255 for its own connection errors; every other exit passes through
    // and closes the surface like a local shell exit.
    #expect(script.contains(#"[ "$gc_rc" -ne 255 ] && exit "$gc_rc""#))
    // Connect runs once, then only the reconnect line retries, with capped backoff.
    #expect(script.contains("DIAL_FIRST"))
    let loopBody = script.range(of: "while :; do").map { script[$0.upperBound...] }
    #expect(loopBody?.contains("DIAL_AGAIN") == true)
    #expect(loopBody?.contains("DIAL_FIRST") == false)
    #expect(script.contains("gc_delay=$((gc_delay * 2))"))
    #expect(script.contains("gc_delay=\(SSHReconnectLoop.maxDelaySeconds)"))
    // Ctrl-C during the wait is the escape hatch.
    #expect(script.hasPrefix("trap 'exit 130' INT; "))
  }

  @Test
  func anAgentSurfaceReconnectNeverRelaunchesTheAgent() throws {
    // The session ending while disconnected is the loop finishing, not a reason to
    // start a second agent pass: the reconnect line reattaches an existing session
    // only, and otherwise closes the pane with a notice.
    let view = surface(launchesClaudeCode: true, prompt: "fix the build")
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains("'get'"))
    #expect(loopBody.contains("attach"))
    #expect(loopBody.contains("ended while disconnected"))
    #expect(!loopBody.contains("claude"))
    #expect(!loopBody.contains("GRAPHCODE_TRIGGER_PROMPT"))
  }

  @Test
  func aShellSurfaceReconnectRecreatesTheShell() throws {
    // A plain shell has no side effect to guard: create-or-attach is the right
    // reconnect, so a tab that died with the host comes back as a fresh shell in the
    // repository.
    let view = surface(launchesClaudeCode: false, prompt: nil)
    let script = try #require(view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    let loopBody = try #require(script.range(of: "while :; do").map { script[$0.upperBound...] })
    #expect(loopBody.contains("attach"))
    #expect(loopBody.contains("/home/dev/widget"))
    #expect(!loopBody.contains("'get'"))
  }

  @Test
  func aRemoteSurfaceGetsNoLocalWorkingDirectoryOrBriefing() {
    let view = surface(launchesClaudeCode: true, prompt: "go")
    // The ssh:// path names no local folder; handing it to Ghostty would fail the
    // spawn. The cd happens inside the remote command instead — and the briefing is
    // not a local *file* either: `remoteBriefingPath` names the delivered copy.
    #expect(view.effectiveWorkingDirectory == nil)
    #expect(view.briefingFile(settings: GraphcodeSettings()) == nil)
  }

  @Test
  func aRemoteAgentSurfaceIsBriefedAtItsOwnHostsPath() throws {
    // The attach creates the session when the daemon hasn't (a turn-based loop's only
    // ever starts here), so it must deliver and reference the same remote briefing
    // the daemon's ensure does — or exactly the loops a human steers most closely
    // would be the ones that never learn they can fan out.
    let view = surface(launchesClaudeCode: true, prompt: "go")
    let script = try #require(
      view.remoteCommand(at: location, settings: GraphcodeSettings()).last)
    #expect(script.contains("--append-system-prompt-file ~/.graphcode/briefings/"))
    // The delivery fragment rides the same dial, ahead of the attach.
    #expect(script.contains("b64decode"))

    #expect(
      view.remoteBriefingPath(settings: GraphcodeSettings())?
        .hasPrefix("~/.graphcode/briefings/") == true)
    let disabled = GraphcodeSettings(briefsSessionsAboutTheGraph: false)
    #expect(view.remoteBriefingPath(settings: disabled) == nil)
  }

  // MARK: - The add form

  @Test
  func theDraftRequiresAHostAnAbsolutePathAndTheWholeDial() {
    var draft = WelcomeFeature.RemoteDraft()
    // User and port arrive prefilled with ssh's own defaults — visible, not implied.
    #expect(!draft.user.isEmpty)
    #expect(draft.port == "22")
    #expect(!draft.canSubmit)
    draft.server = "build-box"
    draft.remotePath = "~/widget"
    // `~` means nothing until the remote shell expands it; identity can't be ambiguous.
    #expect(draft.location == nil)
    draft.remotePath = "/home/dev/widget"
    #expect(draft.canSubmit)
    draft.port = "not-a-port"
    #expect(draft.location == nil)
    draft.port = "22"
    // Clearing either half of the dial blocks submission: left empty they fell through
    // to whatever ssh guessed, and on machines where the remote side differs the dial
    // silently went to the wrong place.
    draft.user = ""
    #expect(draft.location == nil)
    draft.user = "dev"
    draft.port = ""
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
    // The port rides in the identity now — every new remote path carries the full dial.
    #expect(await opened.paths == ["ssh://dev@build-box:22/home/dev/widget"])
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

  // MARK: - Connection info

  @Test
  @MainActor
  func connectionInfoFillsTheSheetFromTheProjectPath() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .remoteConnectionRequested(projectPath: "ssh://dev@build-box:2222/home/dev/widget"))

    let draft = store.state.remoteDraft
    #expect(draft?.server == "build-box")
    #expect(draft?.user == "dev")
    #expect(draft?.port == "2222")
    #expect(draft?.remotePath == "/home/dev/widget")
    // Read-only: the ssh:// path *is* the project's identity, so submitting an edited
    // dial would open a second project rather than change this one.
    #expect(draft?.isInspecting == true)
    #expect(draft?.canSubmit == false)
  }

  @Test
  @MainActor
  func aLocalFolderHasNoConnectionInfoToShow() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    }
    store.exhaustivity = .off

    await store.send(.remoteConnectionRequested(projectPath: "/Users/dev/widget"))

    #expect(store.state.remoteDraft == nil)
  }

  @Test
  @MainActor
  func inspectingRefusesToSubmit() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.remoteRepositoryClient.validate = { _ in nil }
      $0.orchestratorClient.send = { _ in
        Issue.record("inspecting a remote must not re-open it")
      }
    }
    store.exhaustivity = .off

    await store.send(
      .remoteConnectionRequested(projectPath: "ssh://dev@build-box:22/home/dev/widget"))
    await store.send(.remoteSubmitted)
    await store.finish()

    #expect(store.state.remoteDraft?.isValidating == false)
  }
}

private actor OpenedRemoteProjectsBox {
  var paths: [String] = []
  func append(_ path: String) { paths.append(path) }
}
