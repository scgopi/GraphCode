import ComposableArchitecture
import SwiftUI

/// Check for Updates' dialogs and the install-progress indicator, applied to `AppView`'s
/// dialog host. Every button reads `offeredUpdate`, never the presenting alert's own
/// state: SwiftUI clears an alert's presentation binding *before* it runs the tapped
/// button's action, which is how the shipped Download button managed to do nothing (#35).
struct UpdateDialogs: ViewModifier {
  let store: StoreOf<AppFeature>

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
