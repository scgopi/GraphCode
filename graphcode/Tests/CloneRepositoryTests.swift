import ComposableArchitecture
import Foundation
import GraphcodeKit
import Testing

@testable import graphcode

/// Adding a project from a remote repository URL — the clone form's state machine and
/// the URL parsing under it. The clone itself is `git`'s job; what graphcode owns is
/// that a success opens the folder through the standard path and a failure keeps the
/// sheet open with something readable in it.
@Suite
struct CloneRepositoryTests {
  // MARK: - URL parsing

  @Test
  func theHumanishNameMatchesGitsOwn() {
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/acme/widget.git") == "widget")
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/acme/widget") == "widget")
    #expect(GitClient.humanishName(forCloneURL: "https://github.com/acme/widget/") == "widget")
    // scp-style remotes aren't URLs Foundation can parse; the name still derives.
    #expect(GitClient.humanishName(forCloneURL: "git@github.com:acme/widget.git") == "widget")
    #expect(GitClient.humanishName(forCloneURL: "https://host/repo.git?ref=x") == "repo")
    #expect(GitClient.humanishName(forCloneURL: "") == "")
  }

  @Test
  func credentialsAreFoundOnlyWhereTheyAreSecrets() {
    // An https token or user:password is a secret to blank out of shown output.
    #expect(GitClient.cloneCredentials(of: "https://tok123@github.com/a/b.git") == "tok123")
    #expect(GitClient.cloneCredentials(of: "https://me:pw@host/a.git") == "me:pw")
    // An ssh login name is not a secret, and scp-style isn't parseable anyway.
    #expect(GitClient.cloneCredentials(of: "git@github.com:a/b.git") == nil)
    #expect(GitClient.cloneCredentials(of: "https://github.com/a/b.git") == nil)
  }

  @Test
  func cloneUsesNativeSeparatedArgumentsAndRedactsCredentials() {
    let url = "https://token@example.com/acme/über.git"
    let destination = #"C:\Users\me\Проекты\über"#
    let arguments = GitClient.cloneArguments(
      url: url, destinationPath: destination, branch: "main", depth: 1)

    #expect(Array(arguments.prefix(3)) == ["git", "clone", "--progress"])
    #expect(arguments.contains("--"))
    #expect(arguments.last == destination)
    #expect(
      GitClient.redactCloneOutput(
        "fatal: https://token@example.com/acme/über.git", credentials: "token")
        == "fatal: https://•••@example.com/acme/über.git")
    #expect(arguments[arguments.firstIndex(of: "--")! + 1] == url)
  }

  // MARK: - Draft derivations

  @Test
  func theDestinationComesFromLocationPlusEffectiveName() {
    var draft = WelcomeFeature.CloneDraft()
    draft.repositoryURL = "https://github.com/acme/widget.git"
    draft.locationPath = "/tmp/checkouts"
    #expect(draft.destinationURL?.path == "/tmp/checkouts/widget")

    // A typed folder name overrides the derived one.
    draft.folderName = "widget-fork"
    #expect(draft.destinationURL?.path == "/tmp/checkouts/widget-fork")

    // No location, no destination — the Clone button stays off.
    draft.locationPath = " "
    #expect(draft.destinationURL == nil)
    #expect(!draft.canSubmit)
  }

  @Test
  func depthMustBeAPositiveWholeNumberWhenGivenAtAll() {
    var draft = WelcomeFeature.CloneDraft()
    draft.repositoryURL = "https://github.com/acme/widget.git"
    draft.locationPath = "/tmp"
    #expect(draft.canSubmit)

    draft.depth = "3"
    #expect(draft.canSubmit)

    draft.depth = "zero"
    #expect(!draft.isDepthValid)
    #expect(!draft.canSubmit)

    draft.depth = "0"
    #expect(!draft.isDepthValid)
  }

  // MARK: - The flow

  private func makeStore(
    clone: @escaping @Sendable () -> AsyncThrowingStream<GitCloneEvent, any Error>,
    opened: OpenedProjectsBox
  ) -> TestStoreOf<WelcomeFeature> {
    let store = TestStore(initialState: WelcomeFeature.State()) {
      WelcomeFeature()
    } withDependencies: {
      $0.gitClient.clone = { _, _, _, _ in clone() }
      $0.orchestratorClient.send = { command in
        if case .openProject(let path) = command { await opened.append(path) }
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  @MainActor
  func aFinishedCloneOpensTheFolderAndDropsTheSheet() async {
    let opened = OpenedProjectsBox()
    let store = makeStore(
      clone: {
        AsyncThrowingStream { continuation in
          continuation.yield(.progress("Receiving objects: 100% (10/10)"))
          continuation.yield(.finished)
          continuation.finish()
        }
      }, opened: opened)

    await store.send(.cloneRepositoryButtonTapped)
    var draft = store.state.cloneDraft ?? WelcomeFeature.CloneDraft()
    draft.repositoryURL = "https://github.com/acme/widget.git"
    draft.locationPath = "/tmp/checkouts"
    await store.send(.binding(.set(\.cloneDraft, draft)))

    await store.send(.cloneSubmitted)
    await store.receive(\.cloneFinished)
    await store.finish()

    // The sheet is down and the clone opened exactly like a picked folder.
    #expect(store.state.cloneDraft == nil)
    #expect(await opened.paths == ["/tmp/checkouts/widget"])
  }

  @Test
  @MainActor
  func aFailedCloneKeepsTheSheetOpenWithGitsExplanation() async {
    let opened = OpenedProjectsBox()
    let store = makeStore(
      clone: {
        AsyncThrowingStream { continuation in
          continuation.finish(
            throwing: GitClientError.commandFailed(
              command: "git clone", status: 128,
              output: "fatal: repository 'x' does not exist"))
        }
      }, opened: opened)

    await store.send(.cloneRepositoryButtonTapped)
    var draft = store.state.cloneDraft ?? WelcomeFeature.CloneDraft()
    draft.repositoryURL = "https://github.com/acme/missing.git"
    draft.locationPath = "/tmp/checkouts"
    await store.send(.binding(.set(\.cloneDraft, draft)))

    await store.send(.cloneSubmitted)
    await store.receive(\.cloneFailed)
    await store.finish()

    let after = store.state.cloneDraft
    #expect(after != nil)
    #expect(after?.isCloning == false)
    #expect(after?.failureMessage?.contains("does not exist") == true)
    #expect(await opened.paths.isEmpty)
  }

  @Test
  @MainActor
  func editingAfterAFailureClearsTheStaleMessage() async {
    let opened = OpenedProjectsBox()
    let store = makeStore(
      clone: { AsyncThrowingStream { $0.finish() } }, opened: opened)

    await store.send(.cloneRepositoryButtonTapped)
    var draft = store.state.cloneDraft ?? WelcomeFeature.CloneDraft()
    draft.failureMessage = "old failure"
    draft.repositoryURL = "https://github.com/acme/retry.git"
    await store.send(.binding(.set(\.cloneDraft, draft)))
    #expect(store.state.cloneDraft?.failureMessage == nil)
  }

  @Test
  @MainActor
  func cancellingDropsTheSheetWithoutOpeningAnything() async {
    let opened = OpenedProjectsBox()
    let store = makeStore(
      clone: { AsyncThrowingStream { _ in } }, opened: opened)

    await store.send(.cloneRepositoryButtonTapped)
    #expect(store.state.cloneDraft != nil)
    await store.send(.cloneCancelled)
    #expect(store.state.cloneDraft == nil)
    #expect(await opened.paths.isEmpty)
  }
}

private actor OpenedProjectsBox {
  var paths: [String] = []
  func append(_ path: String) { paths.append(path) }
}
