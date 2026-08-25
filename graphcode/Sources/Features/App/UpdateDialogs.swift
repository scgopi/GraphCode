import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Check for Updates' dialogs and the install-progress indicator, applied to `AppView`'s
/// dialog host. Every button reads `offeredUpdate`, never the presenting alert's own
/// state: SwiftUI clears an alert's presentation binding *before* it runs the tapped
/// button's action, which is how the shipped Download button managed to do nothing (#35).
struct UpdateDialogs: ViewModifier {
  let store: StoreOf<AppFeature>

  /// "work", "work and oss", "work, oss and side" — named rather than counted, because
  /// the answer someone needs is *which* windows are about to be quit.
  static func list(_ workspaces: [Workspace]) -> String {
    let names = workspaces.map(\.name)
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }

  func body(content: Content) -> some View {
    content
      .alert(
        "GraphCode \(store.offeredUpdate?.version ?? "") is available",
        isPresented: Binding(
          get: { store.availableUpdate != nil },
          set: { if !$0 { store.send(.updateAlertDismissed) } }
        )
      ) {
        Button("Install Update") { store.send(.updateInstallTapped) }
        Button("Release Notes") { store.send(.updateReleaseNotesTapped) }
        Button("Later", role: .cancel) { store.send(.updateAlertDismissed) }
      } message: {
        Text(
          "You're running \(store.offeredUpdate?.currentVersion ?? ""). Install "
            + "downloads the update and puts it in Applications; you pick the moment "
            + "to relaunch.")
      }
      .alert(
        store.updateNotice?.title ?? "",
        isPresented: Binding(
          get: { store.updateNotice != nil },
          set: { if !$0 { store.send(.updateNoticeDismissed) } }
        )
      ) {
        Button("OK") { store.send(.updateNoticeDismissed) }
      } message: {
        Text(store.updateNotice?.message ?? "")
      }
      .modifier(SwappedBundleDialog(store: store))
      .alert(
        "Update installed",
        isPresented: Binding(
          get: { store.isUpdateReadyToRelaunch },
          set: { if !$0 { store.send(.updateRelaunchDismissed) } }
        )
      ) {
        Button("Relaunch Now") { store.send(.updateRelaunchTapped) }
        Button("Later", role: .cancel) { store.send(.updateRelaunchDismissed) }
      } message: {
        Text(
          "GraphCode \(store.offeredUpdate?.version ?? "") is in Applications and "
            + "takes over on the next launch. Sessions keep running through a relaunch "
            + "— the daemon holds them, not the window.")
      }
      // Asked before the swap, not after: every workspace runs from the same copy in
      // /Applications, so installing replaces the bundle underneath any other open
      // window — which is then executing pages that are no longer on disk.
      .confirmationDialog(
        "Other workspaces are open",
        isPresented: Binding(
          get: { store.workspaces.othersOpenForUpdate != nil },
          set: { if !$0 { store.send(.workspaces(.othersForUpdateDismissed)) } }
        ),
        titleVisibility: .visible,
        presenting: store.workspaces.othersOpenForUpdate
      ) { others in
        Button("Quit \(others.count == 1 ? "It" : "Them") & Install") {
          store.send(.workspaces(.quitOthersForUpdate))
        }
        Button("Install Anyway") { store.send(.workspaces(.updateWithoutQuittingOthers)) }
        Button("Cancel", role: .cancel) {
          store.send(.workspaces(.othersForUpdateDismissed))
        }
      } message: { others in
        Text(
          "\(UpdateDialogs.list(others)) \(others.count == 1 ? "is" : "are") open in "
            + "\(others.count == 1 ? "another window" : "other windows"). Every workspace "
            + "runs the same app, so installing replaces it for all of them. Quitting "
            + "them first is the clean way — their loops keep running either way, since "
            + "the daemon holds the sessions, not the window.")
      }
      .alert(
        "Couldn't install the update",
        isPresented: Binding(
          get: { store.updateInstallFailure != nil },
          set: { if !$0 { store.send(.updateInstallFailureDismissed) } }
        )
      ) {
        Button("Download in Browser") { store.send(.updateDownloadTapped) }
        Button("Cancel", role: .cancel) { store.send(.updateInstallFailureDismissed) }
      } message: {
        Text(
          "\(store.updateInstallFailure ?? "") The browser download still works — "
            + "drag GraphCode into Applications to install it.")
      }
      .overlay(alignment: .bottomTrailing) {
        if let fraction = store.updateInstallProgress {
          HStack(spacing: 8) {
            ProgressView(value: min(fraction, 1))
              .frame(width: 110)
            Text(fraction < 1 ? "Downloading update…" : "Installing…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(10)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          .padding(12)
        }
      }
  }
}

/// The relaunch prompt for a bundle that changed underneath a running window, kept apart
/// from `UpdateDialogs` because it is not an update this app performed: nothing was
/// downloaded, nobody was asked, and the first this window hears of it is the copy in
/// /Applications no longer matching the helpers it installed at launch.
struct SwappedBundleDialog: ViewModifier {
  let store: StoreOf<AppFeature>

  func body(content: Content) -> some View {
    content
      // A bundle can also change without this app having installed anything — `brew
      // upgrade`, a DMG dragged over /Applications, an earlier install whose relaunch
      // was declined. The window keeps running code that is no longer on disk and, more
      // to the point, its `graphcoded` stays the old one: the bootstrap that installs
      // the helpers and reloads the daemon runs at launch, so only a relaunch applies
      // it. Asked on activation rather than fixed silently — installing new helpers
      // under an old window would leave a new daemon serving it.
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        store.send(.bundleSwap(.checkRequested))
      }
      .alert(
        "A newer GraphCode is installed",
        isPresented: Binding(
          get: { store.bundleSwap.pending != nil },
          set: { if !$0 { store.send(.bundleSwap(.relaunchDismissed)) } }
        )
      ) {
        Button("Relaunch Now") { store.send(.updateRelaunchTapped) }
        Button("Later", role: .cancel) { store.send(.bundleSwap(.relaunchDismissed)) }
      } message: {
        Text(
          "The copy in Applications has changed since this window opened, so this one "
            + "is still running the old build and its background helper. Relaunching "
            + "picks up both. Sessions keep running through it — the daemon holds them, "
            + "not the window.")
      }
  }
}
