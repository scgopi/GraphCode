import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Rename and Delete, one click from the workspace they act on.
///
/// These were two submenus hanging off `File ▸ Workspace`, which put deleting a workspace
/// four levels down a menu and made the two verbs impossible to compare — you could not
/// see what you were about to delete while deciding to delete it. Here each workspace is
/// a row that says how much is in it, with both verbs on the row.
///
/// The rules are unchanged and still enforced by `Workspace.refusal`: the default
/// workspace and the one this window is using are shown but not actionable, and one open
/// in another window refuses with its reason when tried.
struct ManageWorkspacesView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Workspaces").font(.headline)

      VStack(spacing: 0) {
        ForEach(store.workspaces.known) { workspace in
          row(workspace)
          if workspace.id != store.workspaces.known.last?.id {
            Divider().overlay(.white.opacity(0.06))
          }
        }
      }
      .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1)
      }

      HStack {
        Button("New Workspace…") {
          store.send(.workspaces(.manageDismissed))
          store.send(.workspaces(.newRequested))
        }
        Spacer()
        Button("Done") { store.send(.workspaces(.manageDismissed)) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 480)
  }

  private func row(_ workspace: Workspace) -> some View {
    let isCurrent = workspace.id == store.workspaces.current.id
    let refusal = workspace.refusal(for: .delete, current: store.workspaces.current)
    let summary = store.workspaces.summaries[workspace.id]
    return HStack(spacing: 10) {
      Circle()
        .fill(WorkspaceSwitcherPanel.tint(for: workspace))
        .frame(width: 7, height: 7)

      VStack(alignment: .leading, spacing: 1) {
        Text(workspace.name).font(.system(size: 13))
        Text(WorkspaceSwitcherPanel.subtitle(summary, isCurrent: isCurrent))
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.white.opacity(0.42))
      }

      Spacer(minLength: 12)

      // Said once, on the row, rather than as an alert after the click: the default
      // workspace and the one you are in are never actionable, and the reason is short
      // enough to print.
      if let refusal {
        Text(ManageWorkspacesView.reason(refusal))
          .font(.system(size: 10))
          .foregroundStyle(.white.opacity(0.35))
      } else {
        Button("Rename…") { store.send(.workspaces(.renameRequested(workspace))) }
        Button("Delete…") { store.send(.workspaces(.deleteRequested(workspace))) }
      }
    }
    .padding(.vertical, 9)
    .padding(.horizontal, 12)
  }

  /// The refusal in three words for a row, where the alert's full sentence would wrap.
  static func reason(_ refusal: Workspace.Refusal) -> String {
    switch refusal {
    case .isDefault: return "the default"
    case .isCurrent: return "this window"
    case .isOpen: return "open elsewhere"
    }
  }
}
