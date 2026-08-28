import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The add-remote-repository sheet — a repository on another machine, reached over SSH.
/// Everything is validated before the project is added (reachability, the path being a
/// repo, zmx being installed there), because each of those failures would otherwise
/// surface later as a loop that silently does nothing.
///
/// The same sheet doubles as the read-only view of an already-added remote's connection
/// (`RemoteDraft.isInspecting`), so the connection is described in one place and can't
/// drift between the two.
struct RemoteRepositoryFormView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  private var isInspecting: Bool { store.remoteDraft?.isInspecting == true }

  var body: some View {
    VStack(spacing: 12) {
      Text(isInspecting ? "Remote Connection" : "Add Remote Repository").font(.headline)

      Form {
        if store.remoteDraft?.inspectsCodespace == true {
          // A codespace's dial is `gh codespace ssh -c <name>` — there is no user or
          // port of ours to show, and pretending ssh's defaults were them would lie.
          LabeledContent("Codespace") { value(\.server) }
          LabeledContent("Path") { value(\.remotePath) }
        } else if isInspecting {
          LabeledContent("Server") { value(\.server) }
          LabeledContent("User") { value(\.user) }
          LabeledContent("Port") { value(\.port) }
          LabeledContent("Path") { value(\.remotePath) }
        } else {
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
      }
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      Text(
        isInspecting
          ? "Loops for this project run on the server; this Mac steers them. To point at a "
            + "different server or path, add it as another remote repository."
          : "Needs key-based SSH (no password prompts), and zmx installed on the server. "
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
        if isInspecting {
          Spacer()
          Button("Done") { store.send(.remoteCancelled) }
            .keyboardShortcut(.defaultAction)
        } else {
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
    }
    .padding(24)
    .frame(width: 460)
  }

  /// Selectable rather than a disabled `TextField`: the reason to open this sheet is to
  /// read a value off it, and often to copy it.
  private func value(
    _ keyPath: KeyPath<WelcomeFeature.RemoteDraft, String>
  ) -> some View {
    let text = store.remoteDraft?[keyPath: keyPath] ?? ""
    return Text(text.isEmpty ? "—" : text)
      .font(.system(.body, design: .monospaced))
      .foregroundStyle(text.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
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
