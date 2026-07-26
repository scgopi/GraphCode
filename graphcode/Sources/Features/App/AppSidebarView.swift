import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The left pane, showing every open project — not just one (the multi-project sidebar
/// follow-up to Phase 4, docs/07-roadmap.md#phase-4--projects; before this, opening a
/// folder replaced whatever was open instead of adding to a list, the way supacode's
/// own sidebar lists several repositories at once — drawn on for the overall shape
/// here, no code or text reused).
///
/// One flat `List`, not `Section`/`DisclosureGroup`: a `Section` header isn't a
/// selectable row on macOS, and `DisclosureGroup`'s label swallows taps meant for
/// selection rather than expand/collapse — a plain `ForEach` emitting a header row
/// followed by that project's node rows (only when expanded) gives full control over
/// which tap does which.
struct AppSidebarView: View {
  @Bindable var store: StoreOf<AppFeature>

  @State private var collapsedProjectPaths: Set<String> = []

  private enum SidebarSelection: Hashable {
    case project(String)
    case node(UUID)
  }

  var body: some View {
    List(selection: selectionBinding) {
      ForEach(store.projects) { project in
        projectHeaderRow(for: project)
          .tag(SidebarSelection.project(project.id))

        if !collapsedProjectPaths.contains(project.id) {
          ForEach(project.graph.nodes) { node in
            nodeRow(for: node)
              .tag(SidebarSelection.node(node.id))
          }
        }
      }
    }
    .listStyle(.sidebar)
    // The sidebar's own translucent material would ignore `Theme` and let the desktop
    // through, so hide it and fill with the flat gray instead.
    .scrollContentBackground(.hidden)
    .background(Theme.sidebarBackground)
    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        addFolderMenu
      }
    }
    .fileImporter(
      isPresented: Binding(
        get: { store.welcome.isOpenPanelPresented },
        set: { store.send(.welcome(.setOpenPanelPresented($0))) }
      ),
      allowedContentTypes: [.folder]
    ) { result in
      store.send(.welcome(.folderPickerResult(result)))
    }
  }

  private var addFolderMenu: some View {
    Menu {
      Button {
        store.send(.welcome(.openFolderButtonTapped))
      } label: {
        Label("Open Folder…", systemImage: "folder")
      }
      if !store.welcome.recentProjects.isEmpty {
        Divider()
        ForEach(store.welcome.recentProjects) { project in
          Button(project.name) {
            store.send(.welcome(.recentProjectTapped(project)))
          }
        }
      }
    } label: {
      Label("Add Folder", systemImage: "folder.badge.plus")
    }
    .menuIndicator(.hidden)
  }

  private func projectHeaderRow(for project: ProjectFeature.State) -> some View {
    HStack(spacing: 4) {
      Button {
        toggleExpanded(project.id)
      } label: {
        Image(
          systemName: collapsedProjectPaths.contains(project.id) ? "chevron.right" : "chevron.down"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 12)
      }
      .buttonStyle(.plain)

      Image(systemName: "folder.fill").foregroundStyle(.secondary)
      Text(project.graph.project.name).lineLimit(1)
      Spacer()
    }
    .contentShape(Rectangle())
  }

  private func nodeRow(for node: LoopNode) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(node.title).lineLimit(1)
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
      }
    } icon: {
      Circle().fill(color(for: node.state)).frame(width: 8, height: 8)
    }
    .padding(.leading, 16)
  }

  private var selectionBinding: Binding<SidebarSelection?> {
    Binding(
      get: {
        if let node = store.detail?.node.id { return .node(node) }
        if let path = store.selectedProjectPath { return .project(path) }
        return nil
      },
      set: { selection in
        switch selection {
        case .project(let path):
          store.send(.projectHeaderTapped(path))
        case .node(let id):
          guard
            let path = store.projects.first(where: { $0.graph.nodes[id: id] != nil })?.id
          else { return }
          store.send(.projects(.element(id: path, action: .nodeTapped(id))))
        case nil:
          break
        }
      }
    )
  }

  private func toggleExpanded(_ path: String) {
    if collapsedProjectPaths.contains(path) {
      collapsedProjectPaths.remove(path)
    } else {
      collapsedProjectPaths.insert(path)
    }
  }

  private func color(for state: LoopState) -> Color {
    switch state {
    case .idle: .gray
    case .running: .blue
    case .awaitingInput: .orange
    case .blocked: .orange
    case .succeeded: .green
    case .failed: .red
    case .stalled: .purple
    }
  }
}
