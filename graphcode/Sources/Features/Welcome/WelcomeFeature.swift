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

    /// `<location>/<name>`; nil until both halves are known.
    var destinationURL: URL? {
      let location = locationPath.trimmingCharacters(in: .whitespaces)
      guard !location.isEmpty, !effectiveFolderName.isEmpty else { return nil }
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

  @ObservableState
  struct State: Equatable {
    var recentProjects: [ProjectRef] = []
    var isOpenPanelPresented = false
    var errorMessage: String?
    var cloneDraft: CloneDraft?
    /// The clone sheet's own folder picker, for choosing `locationPath`. A sibling of
    /// `isOpenPanelPresented` rather than a reuse of it: that one's `fileImporter`
    /// opens a project, and a location pick must not.
    var isCloneLocationPickerPresented = false
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case openFolderButtonTapped
    case folderPickerResult(Result<URL, any Error>)
    case recentProjectTapped(ProjectRef)
    case setOpenPanelPresented(Bool)
    case cloneRepositoryButtonTapped
    case cloneLocationPicked(Result<URL, any Error>)
    case cloneSubmitted
    case cloneCancelled
    case cloneProgress(String)
    case cloneFinished(path: String)
    case cloneFailed(String)
  }

  /// Remembers the last clone location across launches, so a burst of clones doesn't
  /// re-pick the parent folder every time. UserDefaults directly rather than
  /// `GraphcodeSettings`: this is UI memory, not configuration anyone chose.
  static let lastCloneLocationKey = "lastCloneLocationPath"

  private enum CancelID { case clone }

  @Dependency(\.orchestratorClient) var orchestratorClient
  @Dependency(\.gitClient) var gitClient

  var body: some ReducerOf<Self> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding(\.cloneDraft):
        // Any edit clears the last failure so a stale message doesn't outlive the
        // input that caused it.
        state.cloneDraft?.failureMessage = nil
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
        return .run { _ in try? await orchestratorClient.send(.openProject(path: path)) }

      case .folderPickerResult(.failure):
        state.errorMessage = "Couldn't read the selected folder."
        return .none

      case .recentProjectTapped(let project):
        return .run { _ in try? await orchestratorClient.send(.openProject(path: project.path)) }

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
      }
    }
  }
}
