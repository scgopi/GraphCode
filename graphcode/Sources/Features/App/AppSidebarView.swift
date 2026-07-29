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
      // would otherwise be indistinguishable from.
      //
      // `folder`, not `folder.fill`, and in label ink rather than `.secondary`: a filled
      // folder at this size is a grey rectangle, and dimmed on top of that it was the
      // least legible thing in the window. See `SidebarIcon`.
      SidebarIcon(
        systemName: project.graph.isGlobal
          ? "point.3.connected.trianglepath.dotted" : "folder",
        tint: project.graph.isGlobal ? Color.accentColor : .primary)
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

}
