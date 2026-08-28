import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// GitHub Codespaces as remote projects: the `codespace://` identity, the
/// `gh codespace ssh` dial every remote effect rides, and the add form's
/// list-pick-validate flow. Everything above the dial is the ssh remote machinery,
/// covered by `RemoteRepositoryTests` — these tests pin down only what differs.
@Suite
struct CodespaceTests {
  private let location = RemoteProjectLocation(
    host: "dev-widget-x5jq4w", remotePath: "/workspaces/widget", isCodespace: true)

  // MARK: - Identity

  @Test
  func theCodespacePathRoundTripsThroughParse() {
    let path = location.projectPath
    #expect(path == "codespace://dev-widget-x5jq4w/workspaces/widget")
    #expect(RemoteProjectLocation.parse(projectPath: path) == location)
  }

  @Test
  func onlyRealCodespacePathsParse() {
    // No name, no absolute path, or an option-shaped name (`gh -c <name>` must never
    // read a stored name as a flag) — all take the local branch.
    #expect(RemoteProjectLocation.parse(projectPath: "codespace://") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "codespace://name") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "codespace://-x/srv/repo") == nil)
    // A user or port has no meaning gh would honour; refusing them keeps one spelling
    // per codespace, which is what "the path is the identity" needs.
    #expect(RemoteProjectLocation.parse(projectPath: "codespace://a@name/srv/repo") == nil)
    #expect(RemoteProjectLocation.parse(projectPath: "codespace://name:22/srv/repo") == nil)
  }

  @Test
  func theDisplayNameCarriesTheCodespaceName() {
    #expect(location.displayName == "widget @ dev-widget-x5jq4w")
  }

  // MARK: - The dial

  @Test
  func codespaceInvocationsDialThroughGh() throws {
    let invocation = location.sshInvocation(remoteCommand: "true")
    #expect(invocation.first == GhLocator.executablePath)
    #expect(
      Array(invocation.dropFirst().prefix(5))
        == ["codespace", "ssh", "-c", "dev-widget-x5jq4w", "--"])
    // The ssh posture rides through past the `--`, and the command stays last.
    #expect(invocation.contains("BatchMode=yes"))
    #expect(invocation.contains("ServerAliveInterval=5"))
    #expect(invocation.contains("ServerAliveCountMax=3"))
    #expect(invocation.last == "true")
    // No ControlMaster: each gh run opens its own tunnel and exits with it, so a
    // persisted master would multiplex later dials over a dead connection.
    #expect(!invocation.contains { $0.contains("ControlMaster") })
    #expect(!invocation.contains { $0.contains("ControlPersist") })

    // Interactive (a terminal surface) allocates a tty; queries must not.
    #expect(!invocation.contains("-t"))
    let interactive = location.sshInvocation(remoteCommand: "x", interactive: true)
    let dashT = try #require(interactive.firstIndex(of: "-t"))
    let separator = try #require(interactive.firstIndex(of: "--"))
    #expect(dashT > separator)
  }

  @Test
  func theSocketForwarderDialsThroughGhToo() {
    let line = RemoteSocketForwarder.forwardCommandLine(
      for: location, localSocketPath: "/tmp/graphcoded.sock")
    #expect(line.contains("'codespace' 'ssh' '-c' 'dev-widget-x5jq4w' '--'"))
    #expect(line.contains("'-N'"))
    #expect(line.contains("ExitOnForwardFailure=yes"))
    // gh names the destination itself: the forward spec must be the last word, not a
    // destination gh would read as the remote command.
    #expect(line.hasSuffix("'/.graphcode/graphcoded.sock:/tmp/graphcoded.sock'"))

    // The plain-ssh line is untouched: destination last, no gh anywhere.
    let ssh = RemoteSocketForwarder.forwardCommandLine(
      for: RemoteProjectLocation(user: "dev", host: "box", remotePath: "/srv/repo"),
      localSocketPath: "/tmp/graphcoded.sock")
    #expect(ssh.hasPrefix("'/usr/bin/ssh'"))
    #expect(ssh.hasSuffix("'dev@box'"))
  }

  // MARK: - The add form

  @Test
  func pickingACodespacePrefillsItsWorkspacePath() {
    let widget = Codespace(
      name: "dev-widget-x5jq4w", displayName: "upbeat widget", repository: "dev/widget",
      state: "Available")
    let gadget = Codespace(
      name: "dev-gadget-9k2m1p", displayName: "gadget", repository: "dev/gadget",
      state: "Shutdown")
    var draft = WelcomeFeature.CodespaceDraft(codespaces: [widget, gadget])
    #expect(!draft.canSubmit)

    #expect(widget.defaultWorkspacePath == "/workspaces/widget")

    draft.selectedName = widget.name
    draft.remotePath = widget.defaultWorkspacePath
    #expect(draft.canSubmit)
    #expect(
      draft.location
        == RemoteProjectLocation(
          host: "dev-widget-x5jq4w", remotePath: "/workspaces/widget", isCodespace: true))

    // The devcontainer can mount elsewhere, so the path stays editable — but it must
    // stay absolute, for the same reason the remote form refuses `~`.
    draft.remotePath = "~/widget"
    #expect(draft.location == nil)
    draft.remotePath = "/workspaces/widget/"
    #expect(draft.location?.remotePath == "/workspaces/widget")
  }

  @Test
  @MainActor
  func aValidatedCodespaceOpensAsAProject() async {
    let widget = Codespace(
      name: "dev-widget-x5jq4w", displayName: "upbeat widget", repository: "dev/widget",
      state: "Available")
    let opened = OpenedCodespaceProjectsBox()
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.codespaceClient.list = { .success([widget]) }
      $0.codespaceClient.githubRepositories = { _ in [] }
      $0.remoteRepositoryClient.validate = { _ in nil }
      $0.orchestratorClient.send = { command in
        if case .openProject(let path) = command { await opened.append(path) }
      }
    }
    store.exhaustivity = .off

    await store.send(.addCodespaceButtonTapped(localProjectPaths: []))
    await store.receive(\.codespacesLoaded)
    await store.send(.codespaceSelected("dev-widget-x5jq4w"))
    #expect(store.state.codespaceDraft?.remotePath == "/workspaces/widget")
    await store.send(.codespaceSubmitted)
    await store.receive(\.codespaceValidated)
    await store.finish()

    #expect(store.state.codespaceDraft == nil)
    #expect(await opened.paths == ["codespace://dev-widget-x5jq4w/workspaces/widget"])
  }

  @Test
  @MainActor
  func aFailedListKeepsTheSheetOpenWithGhsOwnWords() async {
    // The words matter: gh's missing-scope error carries its own fix
    // (`gh auth refresh -h github.com -s codespace`), so it reaches the sheet verbatim.
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.codespaceClient.list = {
        .failure(.init(message: "gh auth refresh -h github.com -s codespace"))
      }
      $0.codespaceClient.githubRepositories = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.addCodespaceButtonTapped(localProjectPaths: []))
    await store.receive(\.codespacesLoaded)
    await store.finish()

    #expect(store.state.codespaceDraft?.listFailure?.contains("codespace") == true)
    #expect(store.state.codespaceDraft?.canSubmit != true)
  }

  @Test
  @MainActor
  func anEmptyListOffersCreatingOneForTheOpenRepositories() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.codespaceClient.list = { .success([]) }
      $0.codespaceClient.githubRepositories = { paths in
        paths == ["/Users/dev/widget"] ? ["dev/widget"] : []
      }
    }
    store.exhaustivity = .off

    await store.send(.addCodespaceButtonTapped(localProjectPaths: ["/Users/dev/widget"]))
    await store.receive(\.codespacesLoaded)
    await store.receive(\.codespaceRepositorySuggestionsLoaded)
    await store.finish()

    #expect(store.state.codespaceDraft?.codespaces == [])
    #expect(store.state.codespaceDraft?.repositorySuggestions == ["dev/widget"])
  }

  @Test
  func everyGitHubOriginSpellingYieldsTheSameRepository() {
    let expected = "dev/widget"
    for origin in [
      "https://github.com/dev/widget.git",
      "https://github.com/dev/widget",
      "git@github.com:dev/widget.git",
      "ssh://git@github.com/dev/widget.git",
    ] {
      #expect(CodespaceClient.githubRepository(fromOriginURL: origin) == expected)
    }
    // Not GitHub, not a repository slug, or option-shaped — no link to offer.
    #expect(CodespaceClient.githubRepository(fromOriginURL: "https://gitlab.com/dev/widget") == nil)
    #expect(CodespaceClient.githubRepository(fromOriginURL: "https://github.com/dev") == nil)
    #expect(CodespaceClient.githubRepository(fromOriginURL: "git@github.com:-x/widget") == nil)
  }

  // MARK: - Connection info

  @Test
  @MainActor
  func connectionInfoShowsTheCodespaceNotAFakeDial() async {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    }
    store.exhaustivity = .off

    await store.send(
      .remoteConnectionRequested(
        projectPath: "codespace://dev-widget-x5jq4w/workspaces/widget"))

    let draft = store.state.remoteDraft
    #expect(draft?.inspectsCodespace == true)
    #expect(draft?.server == "dev-widget-x5jq4w")
    #expect(draft?.remotePath == "/workspaces/widget")
    #expect(draft?.isInspecting == true)
    #expect(draft?.canSubmit == false)
  }
}

private actor OpenedCodespaceProjectsBox {
  var paths: [String] = []
  func append(_ path: String) { paths.append(path) }
}
