import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Renaming a workspace — which means moving its directory, since that directory *is* the
/// workspace. The sheet shows where it lands for the same reason the New Workspace sheet
/// does: that path is what a `GRAPHCODE_SUPPORT_DIR` on the CLI points at.
struct RenameWorkspaceFormView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    VStack(spacing: 12) {
      Text("Rename Workspace").font(.headline)

      Text(
        """
        Its projects, loops and terminal layouts move with it. A session already running \
        in this workspace keeps running, but can't reach the graph again until it is \
        restarted — it still holds the old directory.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      Form {
        TextField("Name", text: name, prompt: Text(store.workspaces.renaming?.name ?? ""))
          .autocorrectionDisabled()
          .onSubmit { if canRename { store.send(.workspaces(.renameConfirmed)) } }
      }
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      Group {
        if let problem = store.workspaces.problem {
          Text(problem).foregroundStyle(.red)
        } else if !directoryPath.isEmpty {
          Text(directoryPath).foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack {
        Button("Cancel") { store.send(.workspaces(.renameCancelled)) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Rename") { store.send(.workspaces(.renameConfirmed)) }
          .keyboardShortcut(.defaultAction)
          .disabled(!canRename)
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private var name: Binding<String> {
    Binding(
      get: { store.workspaces.renameDraft },
      set: { store.send(.workspaces(.renameDraftChanged($0))) })
  }

  /// The unchanged name is not a rename — and it would fail validation as "already
  /// exists", which reads as a bug rather than as nothing to do.
  private var canRename: Bool {
    guard let renaming = store.workspaces.renaming else { return false }
    let draft = store.workspaces.renameDraft
    return store.workspaces.problem == nil && !draft.isEmpty
      && Workspace.slug(from: draft) != renaming.slug
  }

  private var directoryPath: String {
    guard case .success(let workspace) = Workspace.validate(name: store.workspaces.renameDraft)
    else { return "" }
    return (workspace.url.path as NSString).abbreviatingWithTildeInPath
  }
}
