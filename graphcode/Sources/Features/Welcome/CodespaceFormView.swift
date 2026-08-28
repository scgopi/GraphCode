import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The add-codespace sheet — a GitHub Codespace as a remote project, with
/// `gh codespace ssh` as the dial. The picker is `gh codespace list`'s answer, so the
/// sheet is only ever offering codespaces that actually exist; when there are none,
/// it points at GitHub's create page instead — for the repositories already open in
/// GraphCode when it can, generically otherwise.
struct CodespaceFormView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  private static let createURL = URL(string: "https://github.com/codespaces/new")!

  var body: some View {
    VStack(spacing: 12) {
      Text("Add Codespace").font(.headline)

      content

      Text(
        "Loops run in the codespace; this Mac steers them. Needs zmx installed in the "
          + "codespace, and gh signed in with the codespace scope. A stopped codespace "
          + "is started by the connection."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)

      if let failure = store.codespaceDraft?.failureMessage {
        Text(failure)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("Cancel") { store.send(.codespaceCancelled) }
        Spacer()
        if store.codespaceDraft?.isValidating == true {
          ProgressView().controlSize(.small).padding(.trailing, 4)
        }
        Button("Add") { store.send(.codespaceSubmitted) }
          .keyboardShortcut(.defaultAction)
          .disabled(store.codespaceDraft?.canSubmit != true)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  @ViewBuilder
  private var content: some View {
    if let failure = store.codespaceDraft?.listFailure {
      // gh's own words, selectable: the missing-scope error carries its fix
      // (`gh auth refresh -h github.com -s codespace`) and deserves copying verbatim.
      Text(failure)
        .font(.caption)
        .foregroundStyle(.red)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button("Try Again") { store.send(.codespaceListRetryTapped) }
    } else if let codespaces = store.codespaceDraft?.codespaces {
      if codespaces.isEmpty {
        emptyState
      } else {
        picker(codespaces)
        pathField
        createLinks(compact: true)
      }
    } else {
      ProgressView("Asking gh for your codespaces…")
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No codespaces yet.")
        .foregroundStyle(.secondary)
      Text("Create one on GitHub, then come back here to add it:")
        .font(.caption)
        .foregroundStyle(.secondary)
      createLinks(compact: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  /// The create page, repository-first: one link per GitHub repository already open
  /// in GraphCode (`codespaces.new/owner/repo` — the badge quick-start URL), then the
  /// generic picker for everything else.
  private func createLinks(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(store.codespaceDraft?.repositorySuggestions ?? [], id: \.self) { repository in
        if let url = URL(string: "https://codespaces.new/\(repository)") {
          Link("Create a codespace for \(repository)…", destination: url)
        }
      }
      Link(
        compact ? "Create a new codespace on GitHub…" : "Create a codespace on GitHub…",
        destination: Self.createURL)
    }
    .font(compact ? .caption : .body)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func picker(_ codespaces: [Codespace]) -> some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(codespaces) { codespace in
          row(codespace)
        }
      }
    }
    .frame(maxHeight: 160)
    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
  }

  private func row(_ codespace: Codespace) -> some View {
    let isSelected = store.codespaceDraft?.selectedName == codespace.name
    return Button {
      store.send(.codespaceSelected(codespace.name))
    } label: {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(codespace.displayName.isEmpty ? codespace.name : codespace.displayName)
            .lineLimit(1)
          Text("\(codespace.repository) · \(codespace.state)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(isSelected ? Color.white.opacity(0.08) : .clear)
    }
    .buttonStyle(.plain)
  }

  private var pathField: some View {
    TextField(
      "Path",
      text: Binding(
        get: { store.codespaceDraft?.remotePath ?? "" },
        set: { newValue in
          guard var draft = store.codespaceDraft else { return }
          draft.remotePath = newValue
          store.send(.binding(.set(\.codespaceDraft, draft)))
        }
      ),
      prompt: Text("/workspaces/repo — absolute")
    )
    .autocorrectionDisabled()
    .font(.system(.body, design: .monospaced))
  }
}
