import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The list of workspaces, as menu items — the same contents whether it is reached from
/// the sidebar's foot or from the File menu.
///
/// Picking one raises the instance that has it open, or launches one. Picking the current
/// workspace does nothing, so the row stays selectable-looking rather than dimmed: a
/// checkmark says which one you are in.
struct WorkspaceMenuItems: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    ForEach(store.workspaces.known) { workspace in
      Button {
        store.send(.workspaces(.switchRequested(workspace)))
      } label: {
        if workspace.id == store.workspaces.current.id {
          Label(workspace.name, systemImage: "checkmark")
        } else {
          Text(workspace.name)
        }
      }
    }
    Divider()
    Button("New Workspace…") { store.send(.workspaces(.newRequested)) }
  }
}

/// The sidebar's foot: which workspace this window is, and the way to another.
///
/// Present only once there is something to disambiguate (`isWorthShowing`) — and needed
/// then, because two workspaces are two instances of the same app with the same icon and
/// the same hidden titlebar, and nothing else on screen says which is which.
struct WorkspaceFooter: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    if store.workspaces.isWorthShowing {
      Menu {
        WorkspaceMenuItems(store: store)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "square.stack.3d.up")
            .imageScale(.small)
          Text(store.workspaces.current.name)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }
}
