import ComposableArchitecture
import Foundation

/// Check for Updates — the app-menu item, the check against GitHub's releases on the
/// install's channel (issue #27; beta channel #33), the in-place install (#37), and the
/// alerts `AppView` hosts for the outcomes.
///
/// Install Update downloads the DMG and swaps it into /Applications itself — see
/// `UpdateInstallClient`; `DaemonBootstrap` re-stages the bundled helpers on the next
/// launch, so the swap plus a relaunch is the whole installation. The browser download
/// stays as the fallback when an install fails, so nobody is ever stranded.
///
/// One trap shapes the state here: SwiftUI clears an alert's `isPresented` binding
/// *before* running the tapped button's action, so any action that needs the offer must
/// read `offeredUpdate` (kept until the next check) rather than `availableUpdate` (the
/// presentation, already nil by then). That was #35 — shipped builds whose Download
/// button did nothing.
/// A copy of GraphCode in /Applications that has changed since this window opened —
/// `brew upgrade`, a DMG dragged over it, an install whose relaunch was declined.
///
/// It matters past cosmetics because the helpers are installed and the daemon reloaded by
/// `DaemonBootstrap.installIfNeeded()` at *launch*: until this window is relaunched it
/// runs an old build over an old `graphcoded`, silently. The stamp is kept rather than a
/// flag so declining answers for that swap and not for every activation after it.
struct BundleSwap: Equatable {
  var pending: String?
  var acknowledged: String?

  @CasePathable
  enum Action: Equatable {
    /// Sent whenever the window comes forward. Three `stat`s and no daemon work — see
    /// `DaemonBootstrap.changedBundleStamp` for why this is not `installIfNeeded`.
    case checkRequested
    case checked(String?)
    case relaunchDismissed
  }
}

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
        // Updates belong to the default workspace — every workspace is the same bundle
        // in /Applications, so this is not per-workspace news. See
        // `WorkspacesState.managesUpdates`; the menu item is disabled elsewhere and this
        // is the backstop for it.
        guard state.workspaces.managesUpdates else { return .none }
        state.isCheckingForUpdates = true
        return .run { send in
          do {
            let current = updateClient.currentVersion()
            let update: AvailableUpdate?
            switch UpdateChannel.channel(
              for: current, override: updateClient.channelOverride())
            {
            case .stable:
              update = AppUpdate.available(
                current: current, release: try await updateClient.latestRelease())
            case .beta:
              update = AppUpdate.available(
                current: current, releases: try await updateClient.allReleases())
            }
            await send(.updateCheckCompleted(.success(update)))
          } catch {
            await send(.updateCheckCompleted(.failure(error)))
          }
        }

      case .checkForUpdatesInBackground:
        // Same fetch as the menu item, different manners: no notice on either outcome,
        // and no auto-presented alert on success — the banner is the whole surface. A
        // check already running (the menu item, another launch tick) owns the result.
        guard !state.isCheckingForUpdates else { return .none }
        // Updates belong to the default workspace — every workspace is the same bundle
        // in /Applications, so this is not per-workspace news. See
        // `WorkspacesState.managesUpdates`; the menu item is disabled elsewhere and this
        // is the backstop for it.
        guard state.workspaces.managesUpdates else { return .none }
        state.isCheckingForUpdates = true
        return .run { send in
          let current = updateClient.currentVersion()
          let update: AvailableUpdate?
          do {
            switch UpdateChannel.channel(
              for: current, override: updateClient.channelOverride())
            {
            case .stable:
              update = AppUpdate.available(
                current: current, release: try await updateClient.latestRelease())
            case .beta:
              update = AppUpdate.available(
                current: current, releases: try await updateClient.allReleases())
            }
          } catch {
            // A launch-time check that can't reach GitHub says nothing — no banner,
            // no alert. The menu item is there for a deliberate retry.
            update = nil
          }
          await send(.updateFoundInBackground(update))
        }

      case .updateFoundInBackground(let update):
        state.isCheckingForUpdates = false
        // Only ever *raise* the banner, never lower it on a transient nil: a flaky
        // launch check must not clear an offer an earlier check already found.
        if let update { state.offeredUpdate = update }
        return .none

      case .updateBannerTapped:
        // The banner stands for the offer; tapping it opens the same alert the menu's
        // successful check would — Install / Release Notes / Later, via `UpdateDialogs`.
        guard state.offeredUpdate != nil else { return .none }
        state.availableUpdate = state.offeredUpdate
        return .none

      case .updateCheckCompleted(.success(let update)):
        state.isCheckingForUpdates = false
        if let update {
          state.availableUpdate = update
          state.offeredUpdate = update
        } else {
          state.offeredUpdate = nil
          state.updateNotice = .upToDate(current: updateClient.currentVersion())
        }
        return .none

      case .updateCheckCompleted(.failure(let error)):
        state.isCheckingForUpdates = false
        state.updateNotice = .checkFailed(error.localizedDescription)
        return .none

      case .updateDownloadTapped:
        guard let update = state.offeredUpdate else { return .none }
        state.availableUpdate = nil
        state.updateInstallFailure = nil
        return .run { _ in await openURL(update.downloadURL) }

      case .updateReleaseNotesTapped:
        guard let update = state.offeredUpdate else { return .none }
        state.availableUpdate = nil
        return .run { _ in await openURL(update.releaseNotesURL) }

      case .updateAlertDismissed:
        state.availableUpdate = nil
        return .none

      case .updateNoticeDismissed:
        state.updateNotice = nil
        return .none

      case .updateInstallTapped:
        guard state.offeredUpdate != nil, state.updateInstallProgress == nil
        else { return .none }
        // Every workspace runs from the same copy in /Applications, so installing swaps
        // the bundle out from under any other open window — which then keeps running an
        // old binary whose pages are no longer on disk. Ask first; `UpdateDialogs` offers
        // to quit them, and either answer comes back as `.updateInstallConfirmed`.
        let others = workspaceClient.otherOpen()
        guard others.isEmpty else {
          state.workspaces.othersOpenForUpdate = others
          state.availableUpdate = nil
          return .none
        }
        return .send(.updateInstallConfirmed)

      case .updateInstallConfirmed:
        guard let update = state.offeredUpdate, state.updateInstallProgress == nil
        else { return .none }
        state.availableUpdate = nil
        state.updateInstallProgress = 0
        return .run { send in
          // The offer can be minutes or days old by the time Install is clicked, and a
          // release cut in between made the flow absurd: the app installed the stale
          // offer, relaunched, and immediately raised a fresh update alert for the
          // version it could have installed the first time. So the channel is checked
          // again at the moment of consent and whatever is newest *now* is what gets
          // installed. A failed or empty re-check falls back to the offered release —
          // the user asked for an install, and the slightly-stale version they were
          // shown beats an error they weren't.
          var chosen = update
          let current = updateClient.currentVersion()
          let fresher: AvailableUpdate? = await {
            switch UpdateChannel.channel(
              for: current, override: updateClient.channelOverride())
            {
            case .stable:
              guard let release = try? await updateClient.latestRelease() else { return nil }
              return AppUpdate.available(current: current, release: release)
            case .beta:
              guard let releases = try? await updateClient.allReleases() else { return nil }
              return AppUpdate.available(current: current, releases: releases)
            }
          }()
          if let fresher, fresher != chosen {
            chosen = fresher
            await send(.updateInstallResolved(fresher))
          }
          // The client's progress callback is synchronous; the stream carries its
          // reports back into this effect so every send stays inside its lifetime.
          let (progress, reporter) = AsyncStream<Double>.makeStream()
          do {
            async let pump: Void = {
              for await fraction in progress {
                await send(.updateInstallProgressed(fraction))
              }
            }()
            try await updateInstallClient.install(chosen.downloadURL) {
              reporter.yield($0)
            }
            reporter.finish()
            await pump
            await send(.updateInstallFinished(.success(chosen.version)))
          } catch {
            reporter.finish()
            await send(.updateInstallFinished(.failure(error)))
          }
        }

      case .updateInstallResolved(let update):
        state.offeredUpdate = update
        return .none

      case .updateInstallProgressed(let fraction):
        // Progress can land after the install already finished or failed; a bar that
        // reappears posthumously is worse than a dropped tick.
        if state.updateInstallProgress != nil { state.updateInstallProgress = fraction }
        return .none

      case .updateInstallFinished(.success):
        state.updateInstallProgress = nil
        state.isUpdateReadyToRelaunch = true
        return .none

      case .updateInstallFinished(.failure(let error)):
        state.updateInstallProgress = nil
        state.updateInstallFailure = error.localizedDescription
        return .none

      case .updateInstallFailureDismissed:
        state.updateInstallFailure = nil
        return .none

      case .bundleSwap(.checkRequested):
        // Nothing to ask while an install is mid-flight or a relaunch is already being
        // offered — both end in the relaunch this would be asking for.
        guard state.updateInstallProgress == nil, !state.isUpdateReadyToRelaunch,
          state.bundleSwap.pending == nil
        else { return .none }
        return .run { send in
          await send(.bundleSwap(.checked(updateClient.swappedBundleStamp())))
        }

      case .bundleSwap(.checked(let stamp)):
        // Only a swap this window has not already been told about: "Later" answers for
        // that bundle, not for every time the app is brought forward afterwards.
        guard let stamp, stamp != state.bundleSwap.acknowledged else { return .none }
        state.bundleSwap.pending = stamp
        return .none

      case .bundleSwap(.relaunchDismissed):
        state.bundleSwap.acknowledged = state.bundleSwap.pending
        state.bundleSwap.pending = nil
        return .none

      case .updateRelaunchTapped:
        state.isUpdateReadyToRelaunch = false
        state.bundleSwap.pending = nil
        return .run { _ in await updateInstallClient.relaunch() }

      case .updateRelaunchDismissed:
        state.isUpdateReadyToRelaunch = false
        return .none

      default:
        return .none
      }
    }
  }
}
