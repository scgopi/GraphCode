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
struct RemoteServerMenuItems: View {
  let store: StoreOf<AppFeature>
  let projectPath: String

  var body: some View {
    if RemoteProjectLocation.parse(projectPath: projectPath) != nil {
      Button("Server Parameters…") {
        store.send(.welcome(.remoteParametersRequested(projectPath: projectPath)))
      }
    }
  }
}
