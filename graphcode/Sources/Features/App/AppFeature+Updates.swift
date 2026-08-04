import ComposableArchitecture
import Foundation

/// Check for Updates — the app-menu item, the check against GitHub's newest stable
/// release, and the two alerts `AppView` hosts for the outcome (issue #27).
///
/// The update itself is a download, not an in-place swap: dragging the DMG's app over
/// /Applications *is* the whole installation — `DaemonBootstrap` re-stages the bundled
/// helpers on next launch — so the flow's job ends at putting the right DMG in front of
/// the human, in the browser, where a large download has progress and resume for free.
extension AppFeature {
  /// A completed check's one-sentence outcome, for the alert that reports it. Only the
  /// "nothing to do" outcomes land here — an actual update gets the richer alert driven
  /// by `State.availableUpdate`.
  struct UpdateNotice: Equatable, Sendable {
    var title: String
    var message: String

    static func upToDate(current: String) -> UpdateNotice {
      UpdateNotice(
        title: "You're up to date",
        message: "GraphCode \(current) is the newest release.")
    }

    static func checkFailed(_ reason: String) -> UpdateNotice {
      UpdateNotice(
        title: "Couldn't check for updates",
        message: "\(reason)\n\nCheck your connection and try again in a while.")
    }
  }

  var updatesReducer: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .checkForUpdatesTapped:
        // A second click while a check is in flight would just race two alerts; the
        // menu item is disabled on this flag, and this guard is the backstop.
        guard !state.isCheckingForUpdates else { return .none }
        state.isCheckingForUpdates = true
        return .run { send in
          do {
            let release = try await updateClient.latestRelease()
            let update = AppUpdate.available(
              current: updateClient.currentVersion(), release: release)
            await send(.updateCheckCompleted(.success(update)))
          } catch {
            await send(.updateCheckCompleted(.failure(error)))
          }
        }

      case .updateCheckCompleted(.success(let update)):
        state.isCheckingForUpdates = false
        if let update {
          state.availableUpdate = update
        } else {
          state.updateNotice = .upToDate(current: updateClient.currentVersion())
        }
        return .none

      case .updateCheckCompleted(.failure(let error)):
        state.isCheckingForUpdates = false
        state.updateNotice = .checkFailed(error.localizedDescription)
        return .none

      case .updateDownloadTapped:
        guard let update = state.availableUpdate else { return .none }
        state.availableUpdate = nil
        return .run { _ in await openURL(update.downloadURL) }

      case .updateReleaseNotesTapped:
        guard let update = state.availableUpdate else { return .none }
        state.availableUpdate = nil
        return .run { _ in await openURL(update.releaseNotesURL) }

      case .updateAlertDismissed:
        state.availableUpdate = nil
        return .none

      case .updateNoticeDismissed:
        state.updateNotice = nil
        return .none

      default:
        return .none
      }
    }
  }
}
