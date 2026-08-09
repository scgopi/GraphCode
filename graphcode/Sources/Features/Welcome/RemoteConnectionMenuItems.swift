import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The verbs a remote folder has and a local one doesn't, shared between the sidebar
/// row's menu and the overview lane caption's — the band *is* the folder, so the two
/// must not disagree about what you can do to it.
///
/// A remote project's connection is only ever visible as the `ssh://` path behind its
/// display name, which reads as "repo @ host" and hides the user, port, and remote path
/// entirely. This is where those are answerable without going to a terminal.
struct RemoteConnectionMenuItems: View {
  let store: StoreOf<AppFeature>
  let projectPath: String

  var body: some View {
    // No ellipsis, unlike the `Project Settings…` above it: nothing is asked of you
    // here, and that pairing is what says which of the two is read-only.
    if RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      Button("Connection Info") {
        store.send(.welcome(.remoteConnectionRequested(projectPath: projectPath)))
      }
    }
  }
}
