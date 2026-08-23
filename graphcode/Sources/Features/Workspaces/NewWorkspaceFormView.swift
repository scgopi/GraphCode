import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Name a workspace, and GraphCode opens it in a second window of its own.
///
/// The sheet shows the directory the name resolves to, because that directory *is* the
/// workspace — it is where its graphs live, what a `GRAPHCODE_SUPPORT_DIR` on the CLI
/// would point at, and what someone deleting a workspace later has to remove.
struct NewWorkspaceFormView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    VStack(spacing: 12) {
      Text("New Workspace").font(.headline)

      Text(
        """
        A workspace keeps its own projects, loops and terminal sessions. Nothing is \
        shared with this one — it opens in a separate window you can put on another \
        screen.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)

      Form {
        TextField(
          "Name", text: name,
          prompt: Text("client work")
        )
        .autocorrectionDisabled()
        .onSubmit { if canCreate { store.send(.workspaces(.createConfirmed)) } }
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
        Button("Cancel") { store.send(.workspaces(.createCancelled)) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Create & Open") { store.send(.workspaces(.createConfirmed)) }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(24)
    .frame(width: 420)
  }

  private var name: Binding<String> {
    Binding(
      get: { store.workspaces.draftName },
      set: { store.send(.workspaces(.draftNameChanged($0))) })
  }

  private var canCreate: Bool {
    store.workspaces.problem == nil && !store.workspaces.draftName.isEmpty
  }

  /// Where the typed name lands, abbreviated the way a human writes it.
  private var directoryPath: String {
    guard case .success(let workspace) = Workspace.validate(name: store.workspaces.draftName)
    else { return "" }
    return (workspace.url.path as NSString).abbreviatingWithTildeInPath
  }
}
