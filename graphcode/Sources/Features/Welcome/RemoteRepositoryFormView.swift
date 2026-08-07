import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The add-remote-repository sheet — a repository on another machine, reached over SSH.
/// Everything is validated before the project is added (reachability, the path being a
/// repo, zmx being installed there), because each of those failures would otherwise
/// surface later as a loop that silently does nothing.
struct RemoteRepositoryFormView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  var body: some View {
    VStack(spacing: 12) {
      Text("Add Remote Repository").font(.headline)

      Form {
        TextField("Server", text: field(\.server), prompt: Text("build-box.local"))
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
        TextField("User", text: field(\.user), prompt: Text("your login on the server"))
          .autocorrectionDisabled()
          .font(.system(.body, design: .monospaced))
        TextField("Port", text: field(\.port), prompt: Text("22"))
          .font(.system(.body, design: .monospaced))
        TextField(
          "Path", text: field(\.remotePath),
          prompt: Text("/home/you/projects/repo — absolute")
        )
        .autocorrectionDisabled()
        .font(.system(.body, design: .monospaced))
      }
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      Text(
        "Needs key-based SSH (no password prompts), and zmx installed on the server. "
          + "Loops run on the server; this Mac steers them."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)

      if let failure = store.remoteDraft?.failureMessage {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("Cancel") { store.send(.remoteCancelled) }
        Spacer()
        if store.remoteDraft?.isValidating == true {
          ProgressView().controlSize(.small).padding(.trailing, 4)
        }
        Button("Add") { store.send(.remoteSubmitted) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.remoteDraft?.canSubmit != true)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  private func field(
    _ keyPath: WritableKeyPath<WelcomeFeature.RemoteDraft, String>
  ) -> Binding<String> {
    Binding(
      get: { store.remoteDraft?[keyPath: keyPath] ?? "" },
      set: { newValue in
        guard var draft = store.remoteDraft else { return }
        draft[keyPath: keyPath] = newValue
        store.send(.binding(.set(\.remoteDraft, draft)))
      }
    )
  }
}
