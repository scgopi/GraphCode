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
///
/// Also owns adding a project from a **remote repository URL** — the clone form. It
/// lives here rather than as a feature of its own because a finished clone is just a
/// folder, and this feature already owns "a folder becomes a project": success routes
/// through the exact same `.openProject` a picked folder takes.
@Reducer
struct WelcomeFeature {
  /// What the clone sheet is collecting and doing. One value, `nil` when the sheet is
  /// down — the same shape `ProjectFeature.PendingEdge` uses for its editor.
  struct CloneDraft: Equatable {
    var repositoryURL = ""
    /// The parent directory the repository is cloned *into*; the leaf is `folderName`.
    var locationPath = ""
    /// Optional override for the destination leaf; blank means the URL-derived name,
    /// which the field shows as its live placeholder.
    var folderName = ""
    var branch = ""
    var depth = ""
    var progressLine: String?
    var isCloning = false
    var failureMessage: String?

    var derivedFolderName: String {
      GitClient.humanishName(forCloneURL: repositoryURL)
    }

    var effectiveFolderName: String {
      let trimmed = folderName.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? derivedFolderName : trimmed
    }

    /// `<location>/<name>`; nil until both halves are known, and nil when the leaf isn't
    /// a plain folder name. The name reaches `git clone` as its destination and, on a
    /// failed clone, `removeItem`; a `..` or `/` in it would place both outside the folder
    /// the human picked, so the destination stays a single safe component of it.
    var destinationURL: URL? {
      let location = locationPath.trimmingCharacters(in: .whitespaces)
      guard !location.isEmpty, SafeArgument.isSafePathComponent(effectiveFolderName)
      else { return nil }
      return URL(fileURLWithPath: location)
        .appendingPathComponent(effectiveFolderName).standardizedFileURL
    }

    var parsedDepth: Int? { Int(depth.trimmingCharacters(in: .whitespaces)) }

    var isDepthValid: Bool {
      depth.trimmingCharacters(in: .whitespaces).isEmpty || (parsedDepth ?? 0) > 0
    }

    var canSubmit: Bool {
      !repositoryURL.trimmingCharacters(in: .whitespaces).isEmpty
        && destinationURL != nil && isDepthValid && !isCloning
    }
  }

  /// What the add-remote-repository sheet is collecting. Validation runs in-feature so
  /// a failure surfaces in the sheet's footer and the sheet stays open — the same
  /// arrangement the clone form uses, for the same reason.
  struct RemoteDraft: Equatable {
    var server = ""
    /// User and port are prefilled, not optional. Left empty they fell through to
    /// whatever ssh guessed — the local username, port 22 — and on machines where the
    /// remote side differs the dial silently went to the wrong place and surfaced
    /// later as an unreachable project. Every new remote identity now carries the
    /// whole dial explicitly; the prefills are just ssh's own defaults made visible.
    var port = "22"
    var user = NSUserName()
    var remotePath = ""
    var isValidating = false
    var failureMessage: String?
    /// Set when the sheet is showing an already-added project's connection instead of
    /// collecting a new one. Read-only in that mode: a remote project's identity *is*
    /// its `ssh://` path, so changing a field here would name a different project rather
    /// than edit this one.
    var inspectedProjectPath: String?
    /// The inspected project is a codespace — `server` holds its name, and the user
    /// and port rows have nothing true to say (gh's tunnel owns both).
    var inspectsCodespace = false

    var isInspecting: Bool { inspectedProjectPath != nil }

    static func inspecting(
      _ location: RemoteProjectLocation, projectPath: String
    ) -> RemoteDraft {
      RemoteDraft(
        server: location.host,
        port: location.port.map(String.init) ?? "22",
        user: location.user ?? "",
        remotePath: location.remotePath,
        inspectedProjectPath: projectPath,
        inspectsCodespace: location.isCodespace)
    }

    /// The location the fields currently describe, or `nil` while they don't describe
    /// one — the Add button's enablement. The path must be absolute: `~` means nothing
    /// until a shell on the *remote* machine expands it, and storing it unexpanded
    /// would bake the ambiguity into the project's identity.
    ///
    /// The path is normalized before it becomes that identity. A trailing slash is the
    /// natural way to type a directory and git never prints one back, which left the two
    /// spellings to be compared as strings elsewhere.
    var location: RemoteProjectLocation? {
      let host = server.trimmingCharacters(in: .whitespaces)
      let path = remotePath.trimmingCharacters(in: .whitespaces)
      let userName = user.trimmingCharacters(in: .whitespaces)
      let portText = port.trimmingCharacters(in: .whitespaces)
      guard SafeArgument.isSafeSSHComponent(host), SafeArgument.isSafeSSHComponent(userName),
        path.hasPrefix("/"),
        let portNumber = Int(portText), (1...65535).contains(portNumber)
      else { return nil }
      return RemoteProjectLocation(
        user: userName, host: host, port: portNumber,
        remotePath: RemoteProjectLocation.normalizedPath(path))
    }

    var canSubmit: Bool { location != nil && !isValidating && !isInspecting }
  }

  @ObservableState
  struct State: Equatable {
    var recentProjects: [ProjectRef] = []
    var isOpenPanelPresented = false
    var errorMessage: String?
    var cloneDraft: CloneDraft?
    var remoteDraft: RemoteDraft?
    var codespaceDraft: CodespaceDraft?
    /// The clone sheet's own folder picker, for choosing `locationPath`. A sibling of
    /// `isOpenPanelPresented` rather than a reuse of it: that one's `fileImporter`
    /// opens a project, and a location pick must not.
    var isCloneLocationPickerPresented = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case openFolderButtonTapped
    case folderPickerResult(Result<URL, any Error>)
    case openProjectFailed(String)
    case recentProjectTapped(ProjectRef)
    case setOpenPanelPresented(Bool)
    case cloneRepositoryButtonTapped
    case cloneLocationPicked(Result<URL, any Error>)
    case cloneSubmitted
    case cloneCancelled
    case cloneProgress(String)
    case cloneFinished(path: String)
    case cloneFailed(String)
    case addRemoteRepositoryButtonTapped
    case remoteConnectionRequested(projectPath: String)
    case remoteSubmitted
    case remoteCancelled
    case remoteValidated(projectPath: String)
    case remoteValidationFailed(String)
    case addCodespaceButtonTapped(localProjectPaths: [String])
    case codespacesLoaded(Result<[Codespace], CodespaceClient.Failure>)
    case codespaceRepositorySuggestionsLoaded([String])
    case codespaceListRetryTapped
    case codespaceSelected(String)
    case codespaceSubmitted
    case codespaceValidated(projectPath: String)
    case codespaceValidationFailed(String)
    case codespaceCancelled
  }

  /// Remembers the last clone location across launches, so a burst of clones doesn't
  /// re-pick the parent folder every time. UserDefaults directly rather than
  /// `GraphcodeSettings`: this is UI memory, not configuration anyone chose.
  static let lastCloneLocationKey = "lastCloneLocationPath"

  private enum CancelID {
    case clone
    case remoteValidation
    case codespaceList
    case codespaceValidation
  }

  @Dependency(\.orchestratorClient) var orchestratorClient
  @Dependency(\.gitClient) var gitClient
  @Dependency(\.remoteRepositoryClient) var remoteRepositoryClient
  @Dependency(\.codespaceClient) var codespaceClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.cloneDraft):
        // Any edit clears the last failure so a stale message doesn't outlive the
        // input that caused it.
        state.cloneDraft?.failureMessage = nil
        return .none

      case .binding(\.remoteDraft):
        state.remoteDraft?.failureMessage = nil
        return .none

      case .binding(\.codespaceDraft):
        state.codespaceDraft?.failureMessage = nil
        return .none

      case .binding:
        return .none

      case .openFolderButtonTapped:
        state.isOpenPanelPresented = true
        return .none

      case .setOpenPanelPresented(let isPresented):
        state.isOpenPanelPresented = isPresented
        return .none

      case .folderPickerResult(.success(let url)):
        let path = url.path
        return openProject(path)

      case .folderPickerResult(.failure):
        state.errorMessage = "Couldn't read the selected folder."
        return .none

      case .openProjectFailed(let message):
        state.errorMessage = message
        return .none

      case .recentProjectTapped(let project):
        return openProject(project.path)

      case .cloneRepositoryButtonTapped:
        var draft = CloneDraft()
        draft.locationPath =
          UserDefaults.standard.string(forKey: Self.lastCloneLocationKey)
          ?? FileManager.default.homeDirectoryForCurrentUser.path
        state.cloneDraft = draft
        return .none

      case .cloneLocationPicked(.success(let url)):
        state.cloneDraft?.locationPath = url.path
        state.cloneDraft?.failureMessage = nil
        return .none

      case .cloneLocationPicked(.failure):
        state.cloneDraft?.failureMessage = "Couldn't read the selected folder."
        return .none

      case .cloneSubmitted:
        guard var draft = state.cloneDraft, draft.canSubmit,
          let destination = draft.destinationURL
        else { return .none }
        draft.isCloning = true
        draft.failureMessage = nil
        draft.progressLine = nil
        state.cloneDraft = draft
        let url = draft.repositoryURL.trimmingCharacters(in: .whitespaces)
        let branch = draft.branch.trimmingCharacters(in: .whitespaces)
        let depth = draft.parsedDepth
        return .run { send in
          let events = gitClient.clone(url, destination, branch.isEmpty ? nil : branch, depth)
          do {
            for try await event in events {
              switch event {
              case .progress(let line):
                await send(.cloneProgress(line))
              case .finished:
                await send(.cloneFinished(path: destination.path))
                return
              }
            }
            // The stream ended without `.finished` or an error — the process was torn
            // down under us. Say so rather than leaving the sheet spinning.
            await send(.cloneFailed("Clone ended unexpectedly."))
          } catch is CancellationError {
            // The sheet was dismissed; nothing to report.
          } catch let error as GitClientError {
            guard case .commandFailed(_, _, let output) = error else {
              return await send(.cloneFailed("Clone failed."))
            }
            await send(.cloneFailed(output.isEmpty ? "Clone failed." : output))
          } catch {
            await send(.cloneFailed(error.localizedDescription))
          }
        }
        .cancellable(id: CancelID.clone, cancelInFlight: true)

      case .cloneProgress(let line):
        state.cloneDraft?.progressLine = line
        return .none

      case .cloneFinished(let path):
        // Remember the parent for next time, then open the clone through the standard
        // path — from here on it is indistinguishable from a picked folder.
        UserDefaults.standard.set(
          (path as NSString).deletingLastPathComponent, forKey: Self.lastCloneLocationKey)
        state.cloneDraft = nil
        return .run { _ in try? await orchestratorClient.send(.openProject(path: path)) }

      case .cloneFailed(let message):
        state.cloneDraft?.isCloning = false
        state.cloneDraft?.progressLine = nil
        state.cloneDraft?.failureMessage = message
        return .none

      case .cloneCancelled:
        state.cloneDraft = nil
        return .cancel(id: CancelID.clone)

      case .addRemoteRepositoryButtonTapped:
        state.remoteDraft = RemoteDraft()
        return .none

      case .remoteConnectionRequested(let projectPath):
        guard let location = RemoteProjectLocation.parse(projectPath: projectPath)
        else { return .none }
        state.remoteDraft = .inspecting(location, projectPath: projectPath)
        return .none

      case .remoteSubmitted:
        guard var draft = state.remoteDraft, let location = draft.location, draft.canSubmit
        else { return .none }
        draft.isValidating = true
        draft.failureMessage = nil
        state.remoteDraft = draft
        return .run { send in
          if let failure = await remoteRepositoryClient.validate(location) {
            await send(.remoteValidationFailed(failure))
          } else {
            await send(.remoteValidated(projectPath: location.projectPath))
          }
        }
        .cancellable(id: CancelID.remoteValidation, cancelInFlight: true)

      case .remoteValidated(let projectPath):
        // A validated connection opens like any other project — the ssh:// path is the
        // project's identity from here on (see `RemoteProjectLocation`).
        state.remoteDraft = nil
        return .run { _ in
          try? await orchestratorClient.send(.openProject(path: projectPath))
        }

      case .remoteValidationFailed(let message):
        state.remoteDraft?.isValidating = false
        state.remoteDraft?.failureMessage = message
        return .none

      case .remoteCancelled:
        state.remoteDraft = nil
        return .cancel(id: CancelID.remoteValidation)

      case .addCodespaceButtonTapped(let localProjectPaths):
        state.codespaceDraft = CodespaceDraft()
        // Sequenced, not merged: the suggestions only matter once the list has
        // answered (they render in its empty state), and a fixed order keeps the
        // flow deterministic.
        return .concatenate(
          loadCodespaces(),
          .run { send in
            await send(
              .codespaceRepositorySuggestionsLoaded(
                codespaceClient.githubRepositories(localProjectPaths)))
          }
        )

      case .codespacesLoaded(.success(let codespaces)):
        state.codespaceDraft?.codespaces = codespaces
        state.codespaceDraft?.listFailure = nil
        return .none

      case .codespacesLoaded(.failure(let failure)):
        state.codespaceDraft?.listFailure = failure.message
        return .none

      case .codespaceRepositorySuggestionsLoaded(let repositories):
        state.codespaceDraft?.repositorySuggestions = repositories
        return .none

      case .codespaceListRetryTapped:
        guard state.codespaceDraft != nil else { return .none }
        state.codespaceDraft?.codespaces = nil
        state.codespaceDraft?.listFailure = nil
        return loadCodespaces()

      case .codespaceSelected(let name):
        guard var draft = state.codespaceDraft else { return .none }
        draft.selectedName = name
        draft.failureMessage = nil
        // Prefill only when the human hasn't typed a path of their own — switching
        // picks refreshes a default, never overwrites an edit for another codespace
        // of the same repository.
        let defaults = (draft.codespaces ?? []).map(\.defaultWorkspacePath)
        if draft.remotePath.isEmpty || defaults.contains(draft.remotePath) {
          draft.remotePath = draft.selected?.defaultWorkspacePath ?? ""
        }
        state.codespaceDraft = draft
        return .none

      case .codespaceSubmitted:
        guard var draft = state.codespaceDraft, let location = draft.location,
          draft.canSubmit
        else { return .none }
        draft.isValidating = true
        draft.failureMessage = nil
        state.codespaceDraft = draft
        return .run { send in
          if let failure = await remoteRepositoryClient.validate(location) {
            await send(.codespaceValidationFailed(failure))
          } else {
            await send(.codespaceValidated(projectPath: location.projectPath))
          }
        }
        .cancellable(id: CancelID.codespaceValidation, cancelInFlight: true)

      case .codespaceValidated(let projectPath):
        // Same as a validated remote: the codespace:// path is the project's identity.
        state.codespaceDraft = nil
        return .run { _ in
          try? await orchestratorClient.send(.openProject(path: projectPath))
        }

      case .codespaceValidationFailed(let message):
        state.codespaceDraft?.isValidating = false
        state.codespaceDraft?.failureMessage = message
        return .none

      case .codespaceCancelled:
        state.codespaceDraft = nil
        return .merge(
          .cancel(id: CancelID.codespaceList),
          .cancel(id: CancelID.codespaceValidation))
      }
    }
  }


  /// Ask the daemon to open a folder, and *say so* when it can't be reached. This was a
  /// silent `try?` — on a machine where the daemon never came up (a fresh install whose
  /// bootstrap failed, say), Add Folder did nothing at all, with no error anywhere to
  /// explain why. An error that names the daemon is what turns "the app is broken" into
  /// something diagnosable.
  private func openProject(_ path: String) -> Effect<Action> {
    .run { send in
      do {
        try await orchestratorClient.send(.openProject(path: path))
      } catch {
        await send(
          .openProjectFailed(
            "Couldn't open the folder — the graphcoded daemon didn't respond "
              + "(\(String(describing: error))). Try quitting and reopening GraphCode."))
      }
    }
  }
}

// The codespace half lives in the extension — the reducer above is at the struct-size
// budget, and these are exactly the "trailing helpers" the lint rule wants out of it.
extension WelcomeFeature {
  /// What the add-codespace sheet is collecting: gh's list, one pick, and the path the
  /// repository lives at inside it. Validation is the remote form's — a codespace that
  /// passes is one whose sessions can start — with `gh codespace ssh` as the dial.
  struct CodespaceDraft: Equatable {
    /// `nil` while `gh codespace list` is still running.
    var codespaces: [Codespace]?
    /// Why the list couldn't load — gh missing, or gh's own words (which carry the
    /// fix when the token lacks the `codespace` scope).
    var listFailure: String?
    var selectedName: String?
    var remotePath = ""
    /// `owner/repo` for the open local projects, so an empty list can offer "create
    /// one for the repository you're already working in".
    var repositorySuggestions: [String] = []
    var isValidating = false
    var failureMessage: String?

    var selected: Codespace? {
      guard let selectedName, let codespaces else { return nil }
      return codespaces.first { $0.name == selectedName }
    }

    /// Same normalization rules as the remote form's `location`; the name reaches
    /// `gh -c` as an argument, so it passes the same door check a hostname does.
    var location: RemoteProjectLocation? {
      let path = remotePath.trimmingCharacters(in: .whitespaces)
      guard let name = selectedName, SafeArgument.isSafeSSHComponent(name),
        path.hasPrefix("/")
      else { return nil }
      return RemoteProjectLocation(
        host: name, remotePath: RemoteProjectLocation.normalizedPath(path),
        isCodespace: true)
    }

    var canSubmit: Bool { location != nil && !isValidating }
  }

  func loadCodespaces() -> Effect<Action> {
    .run { send in
      await send(.codespacesLoaded(codespaceClient.list()))
    }
    .cancellable(id: CancelID.codespaceList, cancelInFlight: true)
  }
}
