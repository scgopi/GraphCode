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

  // Several of the stored properties and the selection type below are not `private`
  // because the project/node row machinery lives in `AppSidebarView+Rows.swift`, and
  // Swift scopes `private` to a file — same arrangement as `ProjectCanvasView`'s drag
  // state.
  @State var collapsedProjectPaths: Set<String> = []
  /// The project whose loops "Delete Loops…" is about to discard, driving the
  /// confirmation dialog. Local view state: nothing outside this pane needs to know a
  /// dialog is up, and nothing should persist if the app quits mid-prompt.
  @State var projectPendingLoopDeletion: ProjectFeature.State?
  /// The project the Delete dialog is asking about — remove from GraphCode only, or
  /// move the folder to the Trash too. Same local-state rationale as above.
  @State var projectPendingDelete: ProjectFeature.State?
  /// Nodes that are expanded to show their children in the sidebar.
  @State var expandedNodeIDs: Set<UUID> = []
  /// The row the pointer is over, keyed by project path, node id string, or the chats
  /// row's own key — the trailing controls (+ and the disclosure chevron) only draw on
  /// this row, supacode-style: quiet rows, controls on approach.
  @State var hoveredRowKey: String?

  enum SidebarSelection: Hashable {
    case project(String)
    case node(UUID)
    case chat(UUID)
  }

  /// The chat a rename prompt is up for, and what has been typed so far. Local view
  /// state, same rationale as `projectPendingLoopDeletion`.
  @State private var chatPendingRename: QuickChat?
  @State private var chatRenameDraft = ""
  @State private var chatPendingDelete: QuickChat?

  var body: some View {
    // The list's contents live in `sidebarList` and the row groups in their own
    // properties — one literal holding every section pushed the expression past what
    // the type-checker will resolve in reasonable time.
    sidebarList
    .listStyle(.sidebar)
    // Errors used to render only on the Welcome screen, which no longer shows once the
    // sidebar exists — so a failed Add Folder looked like nothing happening at all.
    .safeAreaInset(edge: .bottom) {
      if let errorMessage = store.welcome.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.thinMaterial)
      }
    }
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
      // Reopens the first-launch terminology primer — its whole audience is someone
      // who dismissed it before the words had anything on screen to stick to.
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.onboardingRequested)
        } label: {
          Label("GraphCode Basics", systemImage: "questionmark.circle")
        }
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
    .confirmationDialog(
      "Delete this project?",
      isPresented: Binding(
        get: { projectPendingDelete != nil },
        set: { if !$0 { projectPendingDelete = nil } }
      ),
      presenting: projectPendingDelete
    ) { project in
      Button("Remove from GraphCode") {
        store.send(.projectRemoveTapped(project.id))
        projectPendingDelete = nil
      }
      // A remote project's folder lives on another machine — offering to trash it
      // locally would be a lie, so the choice narrows to removal.
      if RemoteProjectLocation.parse(projectPath: project.id) == nil {
        Button("Move Folder to Trash", role: .destructive) {
          store.send(.projectDeleteFromDiskConfirmed(project.id))
          projectPendingDelete = nil
        }
      }
      Button("Cancel", role: .cancel) { projectPendingDelete = nil }
    } message: { project in
      Text(
        """
        Remove \(project.graph.project.name) from GraphCode — its saved loops survive \
        for whenever you re-add it — or also delete its loops and move the folder to \
        the Trash, where it stays recoverable.
        """)
    }
    .alert(
      "Rename Chat",
      isPresented: Binding(
        get: { chatPendingRename != nil },
        set: { if !$0 { chatPendingRename = nil } }
      ),
      presenting: chatPendingRename
    ) { chat in
      TextField("Title", text: $chatRenameDraft)
      Button("Rename") {
        store.send(.quickChatRenamed(id: chat.id, title: chatRenameDraft))
        chatPendingRename = nil
      }
      Button("Cancel", role: .cancel) { chatPendingRename = nil }
    }
    .confirmationDialog(
      "Delete this chat?",
      isPresented: Binding(
        get: { chatPendingDelete != nil },
        set: { if !$0 { chatPendingDelete = nil } }
      ),
      presenting: chatPendingDelete
    ) { chat in
      Button("Delete Chat", role: .destructive) {
        store.send(.quickChatDeleteConfirmed(chat.id))
        chatPendingDelete = nil
      }
      Button("Cancel", role: .cancel) { chatPendingDelete = nil }
    } message: { chat in
      Text("\(chat.title)'s session and scrollback will be permanently deleted.")
    }
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
  /// No loop-type glyph here on purpose — in a narrow list of small rows the coloured
  /// icons read as noise, and the caption underneath already names the type. The canvas
  /// keeps its glyphs; the type's colour matters there, where the cards have room.
  func nodeRow(for node: LoopNode) -> some View {
    HStack(spacing: 6) {
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
        if let id = store.openLoop?.node.id {
          return store.quickChats[id: id] != nil ? .chat(id) : .node(id)
        }
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
        case .chat(let id):
          store.send(.quickChatTapped(id))
        case nil:
          break
        }
      }
    )
  }

  private var sidebarList: some View {
    List(selection: selectionBinding) {
      attentionSection
      // The Graph first, then Quick Chats as a project-like row of its own — a peer of
      // the folders, just not tied to one — then the folders, split by where they
      // live. The dividers are what make the sidebar read as sections: the app's own
      // surfaces on top, local folders next, remote repositories last.
      if let global = store.projects.first(where: { $0.graph.isGlobal }) {
        projectGroup(for: global)
      }
      quickChatsGroup
      let folders = store.projects.filter { !$0.graph.isGlobal }
      let localFolders = folders.filter {
        RemoteProjectLocation.parse(projectPath: $0.id) == nil
      }
      let remoteFolders = folders.filter {
        RemoteProjectLocation.parse(projectPath: $0.id) != nil
      }
      if !localFolders.isEmpty {
        Divider()
          .padding(.vertical, 4)
      }
      ForEach(localFolders) { project in
        projectGroup(for: project)
      }
      if !remoteFolders.isEmpty {
        Divider()
          .padding(.vertical, 4)
      }
      ForEach(remoteFolders) { project in
        projectGroup(for: project)
      }
    }
  }

  // MARK: - Quick chats

  @State private var chatsCollapsed = false
  static let chatsRowKey = "quick-chats"

  /// Quick Chats drawn as a project-like row between the Graph and the folders: the
  /// same header-then-indented-children shape as a folder, because that's what it is —
  /// another project, just not tied to a folder on disk. Not a `Section`, whose grey
  /// header read as a disabled control sitting above everything it wasn't.
  @ViewBuilder
  private var quickChatsGroup: some View {
    HStack(spacing: 6) {
      SidebarIcon(systemName: "bubble.left.and.bubble.right", tint: .primary)
      Text("Quick Chats").lineLimit(1)
      Spacer()
      // Trailing, + then chevron, and only under the pointer — the supacode
      // arrangement every header row now follows; see `projectHeaderRow`.
      if hoveredRowKey == Self.chatsRowKey {
        Button {
          store.send(.newQuickChatTapped)
        } label: {
          Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("New Quick Chat")
        if !store.quickChats.isEmpty {
          Button {
            chatsCollapsed.toggle()
          } label: {
            Image(systemName: chatsCollapsed ? "chevron.right" : "chevron.down")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 12)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering in
      if hovering {
        hoveredRowKey = Self.chatsRowKey
      } else if hoveredRowKey == Self.chatsRowKey {
        hoveredRowKey = nil
      }
    }
    .contextMenu {
      Button("New Chat") { store.send(.newQuickChatTapped) }
    }

    if !chatsCollapsed {
      ForEach(store.quickChats) { chat in
        HStack(spacing: 6) {
          Text(chat.title).lineLimit(1)
          Spacer()
        }
        .contentShape(Rectangle())
        .padding(.leading, 16)
        .tag(SidebarSelection.chat(chat.id))
        .contextMenu {
          Button("Rename…") {
            chatRenameDraft = chat.title
            chatPendingRename = chat
          }
          Divider()
          Button("Delete Chat…", role: .destructive) { chatPendingDelete = chat }
        }
      }
    }
  }


}
