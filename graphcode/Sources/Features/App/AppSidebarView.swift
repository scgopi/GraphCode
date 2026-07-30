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
  /// Nodes that are expanded to show their children in the sidebar.
  @State private var expandedNodeIDs: Set<UUID> = []

  private enum SidebarSelection: Hashable {
    case project(String)
    case node(UUID)
  }

  var body: some View {
    List(selection: selectionBinding) {
      attentionSection

      ForEach(store.projects) { project in
        projectHeaderRow(for: project)
          .tag(SidebarSelection.project(project.id))
          // No menu on the Graph row: it can't be closed, forgotten, or deleted, and a
          // menu of three disabled items reads as a bug rather than as a rule.
          .contextMenu {
            if !project.graph.isGlobal {
              projectMenu(for: project)
            }
          }

        if !collapsedProjectPaths.contains(project.id) {
          let rows = flattenedNodeRows(in: project)
          ForEach(rows) { entry in
            nestedNodeRow(entry, in: project)
          }
          // Drag-to-reorder, scoped to this project's own ForEach: SwiftUI only moves
          // rows within the ForEach the modifier hangs off, which is exactly the rule —
          // a loop rearranges inside its project and can never be dropped into another.
          // Only top-level rows reorder; a child's place is under its parent, so a drag
          // that includes one is ignored rather than half-applied.
          .onMove { offsets, target in
            guard offsets.allSatisfy({ rows[$0].depth == 0 }) else { return }
            var ids = rows.map(\.id)
            ids.move(fromOffsets: offsets, toOffset: target)
            let rootIDs = ids.filter { id in rows.first { $0.id == id }?.depth == 0 }
            store.send(
              .projects(.element(id: project.id, action: .sidebarNodesReordered(rootIDs))))
          }
        }
      }
    }
    .listStyle(.sidebar)
    // The sidebar's own translucent material would ignore `Theme` and let the desktop
    // through, so hide it and paint the chrome instead — see `Theme.sidebarGloss`.
    .scrollContentBackground(.hidden)
    .background {
      Theme.sidebarGloss
        // Lit along the top edge, where the pane meets the titlebar.
        .overlay(alignment: .top) {
          Rectangle().fill(Theme.sidebarHighlight).frame(height: 1)
        }
        // And falling into shadow where the detail pane begins. Drawn on the sidebar
        // rather than as a divider so it sits under the list's own selection highlight
        // instead of on top of it.
        .overlay(alignment: .trailing) {
          Rectangle().fill(Theme.sidebarEdgeShadow).frame(width: 1)
        }
        .ignoresSafeArea()
    }
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
    // The clone sheet. Dismissing it mid-clone cancels the clone — that's
    // `.cloneCancelled`'s job, not a side effect of the binding.
    .sheet(
      isPresented: Binding(
        get: { store.welcome.cloneDraft != nil },
        set: { if !$0 { store.send(.welcome(.cloneCancelled)) } }
      )
    ) {
      CloneRepositoryFormView(store: store.scope(state: \.welcome, action: \.welcome))
    }
    .sheet(
      isPresented: Binding(
        get: { store.welcome.remoteDraft != nil },
        set: { if !$0 { store.send(.welcome(.remoteCancelled)) } }
      )
    ) {
      RemoteRepositoryFormView(store: store.scope(state: \.welcome, action: \.welcome))
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
    Button("Move Up") { store.send(.projectMoveUpTapped(project.id)) }
    Button("Move Down") { store.send(.projectMoveDownTapped(project.id)) }
    Divider()
    Button("Close") { store.send(.projectCloseTapped(project.id)) }
    Button("Remove from GraphCode") { store.send(.projectRemoveTapped(project.id)) }
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
      // A project can also start as a URL — the clone lands locally and opens through
      // the same path a picked folder takes. See `WelcomeFeature.CloneDraft`.
      Button {
        store.send(.welcome(.cloneRepositoryButtonTapped))
      } label: {
        Label("Clone Repository…", systemImage: "square.and.arrow.down.on.square")
      }
      // A repository on another machine, over SSH — loops run there, this Mac steers.
      Button {
        store.send(.welcome(.addRemoteRepositoryButtonTapped))
      } label: {
        Label("Add Remote Repository…", systemImage: "network")
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
    HStack(spacing: 6) {
      // A disclosure control only where there is something to disclose, and no blank
      // held open where there isn't: a row with nothing under it sits flush left, which
      // is itself the signal that it holds no loops. Reserving the space instead would
      // line every row up behind a control half of them don't have — tidier, but it
      // makes an empty folder look identical to a collapsed one.
      if canExpand(project) {
        Button {
          toggleExpanded(project.id)
        } label: {
          Image(
            systemName: collapsedProjectPaths.contains(project.id)
              ? "chevron.right" : "chevron.down"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
        }
        .buttonStyle(.plain)
      }

      // The Graph is not a folder and its row doesn't open one — it opens the whole
      // workspace drawn as one graph (`GraphOverviewView`), so it carries the same
      // connected-nodes glyph the canvas uses for itself rather than a folder icon it
      // would otherwise be indistinguishable from. A remote repository isn't a local
      // folder either: it gets the same `network` glyph the Add Remote Repository menu
      // item wears, so "this one lives on another machine" is readable at a glance —
      // the name alone ("widget @ build-box") only says so once you've read it.
      //
      // `folder`, not `folder.fill`, and in label ink rather than `.secondary`: a filled
      // folder at this size is a grey rectangle, and dimmed on top of that it was the
      // least legible thing in the window. See `SidebarIcon`.
      SidebarIcon(
        systemName: sidebarGlyph(for: project),
        tint: project.graph.isGlobal ? Color.accentColor : .primary)
      Text(project.graph.project.name).lineLimit(1)
      Spacer()
    }
    .contentShape(Rectangle())
  }

  private func sidebarGlyph(for project: ProjectFeature.State) -> String {
    if project.graph.isGlobal { return "point.3.connected.trianglepath.dotted" }
    if RemoteProjectLocation.parse(projectPath: project.id) != nil { return "network" }
    return "folder"
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

    Button("Rename…") { send(.renameNodeRequested(node.id), to: projectPath) }

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

  /// Kind leads, state trails.
  ///
  /// These are two different questions and each still keeps its own place in the row —
  /// but they used to be the other way round, and the leading slot held an 8pt dot. A
  /// sidebar's leading column is its most legible position and a dot is the least
  /// legible thing that can go in one; it was the whole reason these rows were harder to
  /// read than Photos'. So the kind glyph takes the column, at the size every other
  /// leading symbol uses, and the presence dot moves to the trailing edge — which is
  /// where Apple's own sidebars put a row's status (Photos' lock, Mail's unread count).
  ///
  /// The glyph no longer repeats in the caption line underneath, where it was a second
  /// copy of the same fact at a size that made it a smudge.
  private func nodeRow(for node: LoopNode) -> some View {
    HStack(spacing: 6) {
      SidebarIcon(systemName: node.loopType.glyph, tint: node.loopType.accent)
      VStack(alignment: .leading, spacing: 1) {
        Text(node.title).lineLimit(1)
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      Circle().fill(node.state.presenceColor).frame(width: 8, height: 8)
    }
    .contentShape(Rectangle())
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

  /// Whether this row has child rows at all. The Graph never does — its canvas is the
  /// whole workspace rather than that graph's own nodes, and its triggers are created
  /// from the CLI — and a folder doesn't until it has a loop in it.
  private func canExpand(_ project: ProjectFeature.State) -> Bool {
    !project.graph.isGlobal && !project.graph.nodes.isEmpty
  }

  private func toggleExpanded(_ path: String) {
    if collapsedProjectPaths.contains(path) {
      collapsedProjectPaths.remove(path)
    } else {
      collapsedProjectPaths.insert(path)
    }
  }

  /// This project's top-level rows — nodes nothing points at — in the human's
  /// arrangement (`sidebarNodeOrder`), not the graph's insertion order.
  private func orderedRootNodes(in project: ProjectFeature.State) -> [LoopNode] {
    let roots = project.graph.nodes.filter { node in
      !project.graph.edges.contains { $0.to == node.id }
    }
    let order = project.sidebarNodeOrder
    return roots.sorted { a, b in
      (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
    }
  }

  /// One visible row of the nested loop tree: the node, how deep it sits, and whether
  /// it has children to disclose.
  private struct NodeRowEntry: Identifiable {
    let node: LoopNode
    let depth: Int
    let hasChildren: Bool
    var id: UUID { node.id }
  }

  /// The loop tree flattened to the rows currently visible, depth-first — parents
  /// first, each expanded parent followed by its children one level deeper. A flat
  /// emission rather than nested `DisclosureGroup`s for the same reason the file
  /// header gives for projects: the group's label swallows selection taps, and its
  /// List styling outdents children instead of indenting them. `visited` guards
  /// against edge cycles, which the graph explicitly allows (see `CycleGuard`).
  private func flattenedNodeRows(in project: ProjectFeature.State) -> [NodeRowEntry] {
    var rows: [NodeRowEntry] = []
    var visited = Set<UUID>()

    func orderedChildren(of parentID: UUID) -> [LoopNode] {
      let childIDs = project.graph.edges.filter { $0.from == parentID }.map(\.to)
      let order = project.sidebarNodeOrder
      return childIDs.compactMap { project.graph.nodes[id: $0] }
        .sorted { a, b in
          (order.firstIndex(of: a.id) ?? .max) < (order.firstIndex(of: b.id) ?? .max)
        }
    }

    func visit(_ node: LoopNode, depth: Int) {
      guard visited.insert(node.id).inserted else { return }
      let children = orderedChildren(of: node.id)
      rows.append(NodeRowEntry(node: node, depth: depth, hasChildren: !children.isEmpty))
      guard expandedNodeIDs.contains(node.id) else { return }
      for child in children { visit(child, depth: depth + 1) }
    }

    for root in orderedRootNodes(in: project) { visit(root, depth: 0) }
    return rows
  }

  /// A loop row at its place in the tree: indented one step per level — rightward,
  /// under its parent — with a chevron only where there are children to show, the
  /// same no-reserved-blank rule `projectHeaderRow` follows for its own chevron.
  private func nestedNodeRow(_ entry: NodeRowEntry, in project: ProjectFeature.State) -> some View {
    HStack(spacing: 4) {
      if entry.hasChildren {
        Button {
          toggleNodeExpanded(entry.node.id)
        } label: {
          Image(
            systemName: expandedNodeIDs.contains(entry.node.id)
              ? "chevron.down" : "chevron.right"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
        }
        .buttonStyle(.plain)
      }
      nodeRow(for: entry.node)
    }
    .padding(.leading, CGFloat(entry.depth) * 16)
    .tag(SidebarSelection.node(entry.node.id))
    .contextMenu { nodeMenu(for: entry.node, in: project.id) }
  }

  private func toggleNodeExpanded(_ id: UUID) {
    if expandedNodeIDs.contains(id) {
      expandedNodeIDs.remove(id)
    } else {
      expandedNodeIDs.insert(id)
    }
  }

}
