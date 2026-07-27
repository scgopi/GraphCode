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
  /// The project whose loops "Delete Loops…" is about to discard, driving the
  /// confirmation dialog. Local view state: nothing outside this pane needs to know a
  /// dialog is up, and nothing should persist if the app quits mid-prompt.
  @State private var projectPendingLoopDeletion: ProjectFeature.State?

  private enum SidebarSelection: Hashable {
    case project(String)
    case node(UUID)
  }

  /// The orchestrator monitor's needs-attention rollup
  /// (docs/05-orchestrator.md#monitoring-surface), pinned above the projects.
  ///
  /// It lives here rather than in a panel of its own because "surface the one thing that
  /// needs me" only works if it's where you already are. It disappears entirely when
  /// nothing needs attention — an always-present empty queue trains people to stop
  /// looking at it.
  @ViewBuilder
  private var attentionSection: some View {
    let items = store.attentionItems
    if !items.isEmpty {
      Text("Needs attention")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(items) { item in
        attentionRow(for: item)
      }
      Divider()
    }
  }

  /// The usage rollup from docs/05-orchestrator.md#monitoring-surface, in the same panel
  /// as needs-attention because "cost and attention are both things the orchestrator's
  /// monitoring surface exists to answer".
  ///
  /// It always states its coverage — "$0.12 · 2/9 loops reporting" — because graphcode
  /// cannot see inside a running `claude` and only knows what a backend's hooks tell it.
  /// A bare total would read as the whole bill when it might be a fraction of it, and a
  /// cost figure a human might act on has to be honest about what it left out.
  @ViewBuilder
  private var usageSection: some View {
    let usage = store.usageRollup
    if usage.total > 0 {
      HStack(spacing: 6) {
        Image(systemName: "chart.bar").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(usage.headline).font(.callout)
          Text(usage.coverage).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.send(.refreshUsageTapped)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Ask each loop's backend what it has spent")
      }
      Divider()
    }
  }

  private func attentionRow(for item: AttentionItem) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon(for: item.reason))
        .foregroundStyle(color(for: item.reason))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.nodeTitle).font(.callout).lineLimit(1)
        // The project name matters here in a way it doesn't in the per-project rows
        // below: this list is the one place loops from different projects sit together.
        Text("\(item.reason.displayName) · \(item.projectName)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture { store.send(.attentionItemTapped(item)) }
    .contextMenu {
      Button("Stop Loop", role: .destructive) {
        store.send(.stopNodeTapped(projectPath: item.projectPath, nodeID: item.nodeID))
      }
    }
  }

  private func icon(for reason: AttentionReason) -> String {
    switch reason {
    case .failed: return "xmark.octagon.fill"
    case .stalled: return "clock.badge.exclamationmark.fill"
    case .awaitingInput: return "bubble.left.fill"
    case .blocked: return "lock.fill"
    }
  }

  private func color(for reason: AttentionReason) -> Color {
    switch reason {
    case .failed: return .red
    case .stalled: return .purple
    case .awaitingInput: return .orange
    case .blocked: return .orange
    }
  }

  var body: some View {
    List(selection: selectionBinding) {
      attentionSection
      usageSection

      ForEach(store.projects) { project in
        projectHeaderRow(for: project)
          .tag(SidebarSelection.project(project.id))
          .contextMenu { projectMenu(for: project) }

        if !collapsedProjectPaths.contains(project.id) {
          ForEach(project.graph.nodes) { node in
            nodeRow(for: node)
              .tag(SidebarSelection.node(node.id))
              .contextMenu { nodeMenu(for: node, in: project.id) }
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
    .confirmationDialog(
      "Delete this project's loops?",
      isPresented: Binding(
        get: { projectPendingLoopDeletion != nil },
        set: { if !$0 { projectPendingLoopDeletion = nil } }
      ),
      presenting: projectPendingLoopDeletion
    ) { project in
      Button("Delete Loops", role: .destructive) {
        store.send(.projectDeleteLoopsConfirmed(project.id))
        projectPendingLoopDeletion = nil
      }
      Button("Cancel", role: .cancel) { projectPendingLoopDeletion = nil }
    } message: { project in
      Text(
        """
        \(project.graph.project.name)'s nodes and edges will be permanently deleted. \
        The folder itself is not touched.
        """)
    }
  }

  /// Three verbs, deliberately distinct: closing is reversible from the Add Folder menu,
  /// removing forgets the project but keeps its loops for whenever you re-add it, and
  /// deleting throws the loops away. Only the last is destructive, so only it confirms
  /// and carries the destructive role.
  @ViewBuilder
  private func projectMenu(for project: ProjectFeature.State) -> some View {
    Button("Close") { store.send(.projectCloseTapped(project.id)) }
    Button("Remove from Graphcode") { store.send(.projectRemoveTapped(project.id)) }
    Divider()
    Button("Delete Loops…", role: .destructive) { projectPendingLoopDeletion = project }
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

  /// The sidebar lists every loop across every open project, so it's where people
  /// actually reach for a loop — right-clicking one here previously did nothing at all,
  /// with the same actions available only on the canvas card.
  ///
  /// Mirrors `ProjectCanvasView`'s node menu rather than offering a different subset:
  /// two right-click menus on the same object that disagree about what you can do to it
  /// is worse than either menu alone. The actions route into that loop's own project
  /// scope, since the sidebar spans several.
  @ViewBuilder
  private func nodeMenu(for node: LoopNode, in projectPath: String) -> some View {
    Button("Open Terminal") { send(.nodeTapped(node.id), to: projectPath) }

    if node.loopType == .proactive {
      Button("Pilot Once…") { send(.pilotCompositeTapped(node.id), to: projectPath) }
      Button("Arm Schedule") { send(.armCompositeTapped(node.id), to: projectPath) }
        .disabled(!node.pilotState.canArm)
    }

    if !node.isResolved {
      Button("Stop Loop") { send(.stopNodeTapped(node.id), to: projectPath) }
    }

    Divider()

    Button("Delete Loop…", role: .destructive) {
      send(.deleteNodeRequested(node.id), to: projectPath)
    }
  }

  private func send(_ action: ProjectFeature.Action, to projectPath: String) {
    store.send(.projects(.element(id: projectPath, action: action)))
  }

  private func nodeRow(for node: LoopNode) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(node.title).lineLimit(1)
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
      }
    } icon: {
      Circle().fill(node.state.presenceColor).frame(width: 8, height: 8)
    }
    .padding(.leading, 16)
  }

  private var selectionBinding: Binding<SidebarSelection?> {
    Binding(
      get: {
        if let id = store.openLoop?.node.id { return .node(id) }
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

}
