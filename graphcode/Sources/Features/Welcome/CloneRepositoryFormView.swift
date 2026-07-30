import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The clone-a-remote-repository sheet — paste a URL, pick where it lands, and the
/// finished clone opens as an ordinary project. Progress streams into the sheet and a
/// failure keeps it open with git's own explanation, so a typo'd URL costs a retry
/// rather than a reopened form.
struct CloneRepositoryFormView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  var body: some View {
    VStack(spacing: 12) {
      Text("Clone Repository").font(.headline)

      Form {
        TextField(
          "Repository", text: repositoryURL,
          prompt: Text("https://github.com/you/repo.git")
        )
        .autocorrectionDisabled()
        .font(.system(.body, design: .monospaced))

        HStack(spacing: 6) {
          TextField("Location", text: locationPath, prompt: Text("where the clone lands"))
            .font(.system(.body, design: .monospaced))
          Button("Choose…") {
            store.send(.binding(.set(\.isCloneLocationPickerPresented, true)))
          }
        }

        TextField(
          "Folder", text: folderName,
          prompt: Text(derivedFolderPlaceholder))

        TextField("Branch", text: branch, prompt: Text("default branch — optional"))
        TextField("Depth", text: depth, prompt: Text("full history — optional"))
          .font(.system(.body, design: .monospaced))
      }
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      // One line of status: the live progress while cloning, the failure after one,
      // nothing otherwise. Progress lines are git's own (`Receiving objects: 42% …`).
      if let progress = store.cloneDraft?.progressLine, store.cloneDraft?.isCloning == true {
        Text(progress)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let failure = store.cloneDraft?.failureMessage {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("Cancel") { store.send(.cloneCancelled) }
        Spacer()
        if store.cloneDraft?.isCloning == true {
          ProgressView().controlSize(.small).padding(.trailing, 4)
        }
        Button("Clone") { store.send(.cloneSubmitted) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.cloneDraft?.canSubmit != true)
      }
    }
    .padding(24)
    .frame(width: 460)
    .fileImporter(
      isPresented: $store.isCloneLocationPickerPresented,
      allowedContentTypes: [.folder]
    ) { result in
      store.send(.cloneLocationPicked(result.mapError { $0 }))
    }
  }

  private var derivedFolderPlaceholder: String {
    let derived = store.cloneDraft?.derivedFolderName ?? ""
    return derived.isEmpty ? "derived from the URL" : derived
  }

  // Bindings into the optional draft. Writing into a dismissed sheet's draft is a
  // no-op rather than a crash, matching how the reducer treats its own optionals.
  private var repositoryURL: Binding<String> {
    draftBinding(\.repositoryURL)
  }
  private var locationPath: Binding<String> { draftBinding(\.locationPath) }
  private var folderName: Binding<String> { draftBinding(\.folderName) }
  private var branch: Binding<String> { draftBinding(\.branch) }
  private var depth: Binding<String> { draftBinding(\.depth) }

  private func draftBinding(
    _ keyPath: WritableKeyPath<WelcomeFeature.CloneDraft, String>
  ) -> Binding<String> {
    Binding(
      get: { store.cloneDraft?[keyPath: keyPath] ?? "" },
      set: { newValue in
        guard var draft = store.cloneDraft else { return }
        draft[keyPath: keyPath] = newValue
        store.send(.binding(.set(\.cloneDraft, draft)))
      }
    )
  }
}
