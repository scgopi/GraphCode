import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// The left pane, showing every open project — not just one (the multi-project sidebar
/// follow-up to Phase 4, docs/07-roadmap.md#phase-4--projects; before this, opening a
/// folder replaced whatever was open instead of adding to a list).
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
  /// Nodes that are expanded to show their children in the sidebar. Persisted across
  /// launches: this was plain view state, and every relaunch silently folded every
  /// child away again — two running loops "missing" from the sidebar were sitting
  /// behind a chevron that had reset overnight.
  @State var expandedNodeIDs: Set<UUID> = Self.loadExpandedNodeIDs()

  static let expandedNodeIDsDefaultsKey = "sidebarExpandedNodeIDs"

  static func loadExpandedNodeIDs() -> Set<UUID> {
    let stored = UserDefaults.standard.stringArray(forKey: expandedNodeIDsDefaultsKey) ?? []
    return Set(stored.compactMap(UUID.init))
  }
  /// Every edge id seen across the open projects, for telling a loop that has just been
  /// wired under a parent from one that was already there. `nil` until the first
  /// observation, so a relaunch seeds silently instead of springing every parent in the
  /// graph open.
  @State var knownEdgeIDs: Set<UUID>?
  /// What the rows' ages are measured against — the window's one 30s tick, the same one
  /// the canvases' cards use. See `CanvasClock`.
  @State var sidebarNow = Date()
  /// The row the pointer is over, keyed by project path, node id string, or the chats
  /// row's own key — the trailing controls (+ and the disclosure chevron) only draw on
  /// this row: quiet rows, controls on approach.
  @State var hoveredRowKey: String?

  enum SidebarSelection: Hashable {
    case project(String)
    case node(UUID)
    /// The Quick Chats header row — the chats' own canvas, a peer of a folder's.
    case chats
    case chat(UUID)
  }

  var body: some View {
    // The list's contents live in `sidebarList` and the row groups in their own
    // properties — one literal holding every section pushed the expression past what
    // the type-checker will resolve in reasonable time.
    sidebarList
      .listStyle(.sidebar)
      .onReceive(CanvasClock.tick) { sidebarNow = $0 }
      .onChange(of: allEdgeIDs, initial: true) { _, current in
        if let known = knownEdgeIDs {
          expandedNodeIDs.formUnion(
            Self.parentsToExpand(forEdgesNotIn: known, in: store.projects.map(\.graph)))
        }
        knownEdgeIDs = current
      }
      .onChange(of: expandedNodeIDs) { _, expanded in
        UserDefaults.standard.set(
          expanded.map(\.uuidString).sorted(), forKey: Self.expandedNodeIDsDefaultsKey)
      }
      // Errors used to render only on the Welcome screen, which no longer shows once the
      // sidebar exists — so a failed Add Folder looked like nothing happening at all.
      .safeAreaInset(edge: .bottom) { bottomInset }
      // The sidebar is the system's translucent material — Liquid Glass on macOS 26,
      // the classic sidebar material on 15, both automatic for a `.listStyle(.sidebar)`
      // list in a split view. This replaced a painted recess (a gradient + hairline
      // overlays that hid the material with `scrollContentBackground(.hidden)`): Apple's
      // Liquid Glass adoption guidance is that custom backgrounds in split views
      // "overlay or interfere" with the system effect and should be removed outright,
      // not layered. The objections that justified the paint are settled elsewhere —
      // the app forces `.preferredColorScheme(.dark)` so the glass stays dark, and the
      // desktop glowing through is the effect's point, not a leak.
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
      // Add Folder is the sidebar's only toolbar item. GraphCode Basics used to sit
      // beside it, but a second item overflows the narrow column into a » menu — the
      // primer now reopens from Help, where a "teach me the words again" command
      // belongs. See `GraphcodeApp`'s commands.
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
    // The chat rename prompt and delete confirmation are deliberately *not* here — they
    // are hosted by `AppView`, so the Quick Chats canvas can raise the same two dialogs
    // while the sidebar row that also offers them isn't the surface being used. Same
    // arrangement as a loop's; see `AppFeature.State.chatPendingRename`.
  }

  /// The sidebar's foot: the update banner (standing news, waiting to be clicked) over
  /// the Add Folder error. Its own property because inlined in the `safeAreaInset`
  /// closure the two `if let`s pushed the expression past the type-checker's budget.
  @ViewBuilder
  private var bottomInset: some View {
    VStack(spacing: 0) {
      // Hidden while an install is mid-flight (the progress overlay speaks then) or
      // already staged (the relaunch alert does).
      if let update = store.offeredUpdate, store.updateInstallProgress == nil,
        !store.isUpdateReadyToRelaunch
      {
        SidebarUpdateBanner(version: update.version) {
          store.send(.updateBannerTapped)
        }
        .padding(8)
      }
      if let errorMessage = store.welcome.errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.thinMaterial)
      }
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
  /// One loop in the sidebar: kind as a stripe, name, age, state.
  ///
  /// The kind used to be printed underneath as a word, on its own line, in a list where
  /// every row is 12.5pt — two lines to say a thing the canvas says with a colour. A
  /// 3×14pt stripe is the same identity channel the card uses and costs a row nothing,
  /// which leaves the second line free for what a list of running work should say
  /// instead: how long it has been going.
  ///
  /// The state indicator is the card's, not a plain dot: hollow-vs-solid is what keeps
  /// `blocked` apart from `awaitingInput` here as well, where there is no room for a
  /// word. See `LoopStateAppearance`.
  func nodeRow(for node: LoopNode) -> some View {
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(node.loopType.accent)
        .frame(width: 3, height: 14)
      Text(node.title).font(.system(size: 12.5)).lineLimit(1)
      Spacer(minLength: 4)
      Text(LoopCardPresentation.duration(sidebarNow.timeIntervalSince(node.createdAt)))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.5))
      StateIndicator(state: node.displayState, diameter: 7)
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
        switch store.detailSelection {
        case .project(let path): return .project(path)
        case .quickChats: return .chats
        case nil: return nil
        }
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
        case .chats:
          store.send(.quickChatsTapped)
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
      // attentionSection(collapsed: $attentionCollapsed)
      // The Graph first, then Quick Chats as a project-like row of its own — a peer of
      // the folders, just not tied to one — then the folders under captioned group
      // headers, split by where they live: the app's own surfaces on top, local
      // projects next, remote repositories last. Each header folds its whole group
      // with the same hover-chevron manners every other header row has.
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
        sectionHeaderRow(
          "Local Projects", key: Self.localSectionKey, collapsed: $localSectionCollapsed)
        if !localSectionCollapsed {
          ForEach(localFolders) { project in
            projectGroup(for: project)
          }
        }
      }
      if !remoteFolders.isEmpty {
        sectionHeaderRow(
          "Remote Repositories", key: Self.remoteSectionKey,
          collapsed: $remoteSectionCollapsed)
        if !remoteSectionCollapsed {
          ForEach(remoteFolders) { project in
            projectGroup(for: project)
          }
        }
      }
    }
  }

  // MARK: - Folder sections

  /// Whether the Local Projects / Remote Repositories groups are folded away. View
  /// state like the chats' own flag: a fold is a reading preference, not graph state.
  @State private var attentionCollapsed = true
  @State private var localSectionCollapsed = false
  @State private var remoteSectionCollapsed = false
  static let attentionSectionKey = "section-needs-you"
  static let localSectionKey = "section-local-projects"
  static let remoteSectionKey = "section-remote-repositories"

  /// A group caption with the same hover-chevron manners as every header row. Not
  /// selectable — it names the rows below it rather than opening anything — so the
  /// whole row is the toggle rather than just the chevron.
  private func sectionHeaderRow(
    _ title: String, key: String, collapsed: Binding<Bool>
  ) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      Spacer()
      if hoveredRowKey == key {
        Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { collapsed.wrappedValue.toggle() }
    .onHover { hovering in
      if hovering {
        hoveredRowKey = key
      } else if hoveredRowKey == key {
        hoveredRowKey = nil
      }
    }
    // The gap above the caption is what makes the sidebar read as sections at a
    // glance — the caption alone, flush against the previous group's last row, read
    // as one more item in it. Sized to the clear band the reference sidebars put
    // before a muted group label, and carried by the header so it collapses with
    // nothing when the group is absent.
    .padding(.top, 18)
    .padding(.bottom, 2)
  }

  // MARK: - Quick chats

  @State private var chatsCollapsed = false
  static let chatsRowKey = "quick-chats"

  /// Quick Chats drawn as a project-like row between the Graph and the folders: the
  /// same header-then-indented-children shape as a folder, because that's what it is —
  /// another project, just not tied to a folder on disk. Not a `Section`, whose grey
  /// header read as a disabled control sitting above everything it wasn't.
  ///
  /// The header row is selectable for the same reason a folder's is: clicking it opens
  /// the chats' own canvas (`QuickChatsCanvasView`), which is where a chat is created,
  /// renamed, or deleted without hunting for a context menu in the sidebar.
  @ViewBuilder
  private var quickChatsGroup: some View {
    HStack(spacing: 6) {
      SidebarIcon(systemName: "bubble.left.and.bubble.right", tint: .primary)
      Text("Quick Chats").lineLimit(1)
      Spacer()
      // Trailing, + then chevron, and only under the pointer — the arrangement every
      // header row now follows; see `projectHeaderRow`.
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
    .tag(SidebarSelection.chats)
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
          Button("Rename…") { store.send(.quickChatRenameRequested(chat.id)) }
          Divider()
          Button("Delete Chat…", role: .destructive) {
            store.send(.quickChatDeleteRequested(chat.id))
          }
        }
      }
    }
  }
}
