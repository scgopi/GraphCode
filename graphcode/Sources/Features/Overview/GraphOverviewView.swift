import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The **Graph** view — every open folder's loops on one pan/zoom canvas, hanging off a
/// single start node (docs/06-ux-terminals.md#the-graph-view). What the pinned sidebar
/// row above the folders opens.
///
/// Cross-project by nature, so it's scoped to `AppFeature` rather than to any one
/// `ProjectFeature` the way `ProjectCanvasView` is — no single project's store can see
/// the other folders' graphs. Clicking a loop opens that loop's terminal workspace
/// through the exact same action a sidebar row sends, so navigating from here isn't a
/// second way in with its own behaviour.
///
/// **Creates, but never rewires.** The two `+`s a folder's canvas has are both here —
/// New Loop at the top right, and a hover-revealed one on every card that starts a loop
/// handed off from it — because "I can see the loop I want to continue from" is the
/// moment you want to continue from it, and crossing to that folder's canvas first only
/// to click the same handle is a detour. What stays out is rewiring: no dragging cards
/// around, no drawing edges between folders. A `.handoff` between two projects isn't a
/// thing graphcode can express (docs/02-graph-of-loops.md keeps the hierarchy flat and
/// non-recursive), so offering that gesture would only ever end in a refusal. A card's
/// `+` sidesteps it by creating into the folder the parent already belongs to.
struct GraphOverviewView: View {
  @Bindable var store: StoreOf<AppFeature>

  /// Where the canvas is looking. See `CanvasTransform` for why the scale and offset are
  /// one value with arithmetic on it rather than two numbers the gestures nudge.
  @State private var transform = CanvasTransform()
  @State private var dragOffset: CGSize = .zero
  /// The scale the current pinch started from. `MagnifyGesture.magnification` is
  /// relative to the start of *that* gesture, so without a captured baseline every new
  /// pinch would snap the canvas back to 1× before it moved anywhere.
  @State private var pinchBaseScale: CGFloat?
  /// The pane's size, kept so the zoom buttons and shortcuts — which have no gesture
  /// location to work from — can still zoom about its centre.
  @State private var viewport: CGSize = .zero
  /// What the cards' elapsed labels are measured against, advanced by the window's one
  /// 30-second tick — see `CanvasClock`.
  @State private var now = Date()

  /// Everything this view draws that is *derived* from the store rather than stored in
  /// it, built once per body pass and handed to the layers.
  ///
  /// A performance contract, the same one `ProjectCanvasView.body` documents, and this is
  /// where it was costing the most. `GraphOverview` lays out every open folder's whole
  /// graph, and `attentionReasons` rolls up across all of them — both were computed
  /// properties the layers read directly, so a single body pass built the overview seven
  /// times over and re-rolled every project's attention state *once per loop card*, which
  /// is quadratic in the number of loops on screen. Panning re-evaluates this body on
  /// every pointer event, so all of it ran on the main thread at gesture rate.
  struct Derived {
    let overview: GraphOverview
    /// The cross-project queue, for the rail.
    let attentionItems: [AttentionItem]
    /// Which loops want a human, by node id — the same rollup the sidebar's monitor and
    /// every project canvas use, so the overview can't disagree with either about what
    /// "needs attention" means.
    let attentionReasons: [UUID: AttentionReason]

    init(overview: GraphOverview, attentionItems: [AttentionItem]) {
      self.overview = overview
      self.attentionItems = attentionItems
      attentionReasons = Dictionary(
        attentionItems.map { ($0.nodeID, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }
  }

  /// This view once had no toolbar on purpose — global triggers were CLI-only. That
  /// rule made the global graph's one legitimate use from the app unreachable: loops
  /// that belong to no folder, like an email or Teams-message watcher, had nowhere a
  /// human could create them. "New Loop" here files the loop into the global graph
  /// through the same `ProjectFeature` form a folder's canvas uses; its session opens
  /// at home (see `ZmxSessionLauncher.workingDirectory`), since there is no project
  /// directory for it to belong to.
  var body: some View {
    let derived = Derived(
      overview: GraphOverview(
        graphs: store.projects.map(\.graph),
        declaredEntries: Dictionary(
          uniqueKeysWithValues: store.projects.map { ($0.id, $0.declaredEntryIDs) })),
      attentionItems: store.attentionItems)

    return canvas(derived)
      .overlay(alignment: .bottomTrailing) { zoomControls(derived.overview) }
      .background(Theme.windowBackground)
      .onReceive(CanvasClock.tick) { now = $0 }
      // In screen space, not canvas space: the queue has to stay put while the graph
      // pans under it, which is the whole point of a rail over a halo you pan-hunt for.
      .overlay(alignment: .topLeading) {
        CanvasAttentionRail(items: derived.attentionItems, now: now) {
          store.send(.reviewAttentionTapped)
        }
      }
      // On the canvas top-right rather than in the toolbar, same placement and quiet
      // styling as a project canvas's New Loop — see there for why.
      .overlay(alignment: .topTrailing) {
        CanvasAddButton(help: "New Loop") {
          store.send(
            .projects(
              .element(
                id: LoopGraphScope.globalPath,
                action: .addNodeButtonTapped(parentBackend: nil))))
        }
        .padding(.trailing, 20)
        .padding(.top, 18)
      }
      .background { nodeFormHosts }
  }

  /// One host per open folder, all of them mounted for the life of this view.
  ///
  /// Two forms can be opened from here now — the global graph's, from the New Loop
  /// button, and any folder's, from a card's `+` handle — and which folder the second
  /// one belongs to isn't known until the click. Mounting a host per folder rather than
  /// inserting one when a form opens is what makes the sheet actually present: a
  /// `.sheet` whose host arrives in the same update that flips its binding misses the
  /// transition and shows nothing. Only one can be open at a time, so the rest are
  /// `Color.clear` with a `false` binding.
  private var nodeFormHosts: some View {
    ForEach(store.scope(state: \.projects, action: \.projects), id: \.state.id) { projectStore in
      NodeFormHost(store: projectStore)
    }
  }

  /// Hosts one folder's node form. A separate view because the sheet binds to the
  /// *project-scoped* store's `showingNewNodeForm`, and `@Bindable` needs a concrete
  /// store to hold — the overview's own store is the whole app's.
  private struct NodeFormHost: View {
    @Bindable var store: StoreOf<ProjectFeature>

    var body: some View {
      Color.clear
        .sheet(isPresented: $store.showingNewNodeForm) {
          NodeDraftForm(store: store)
        }
    }
  }

  /// Scale and offset as the canvas is currently drawn — the committed transform plus
  /// whatever the in-flight pan has moved so far.
  private var liveOffset: CGSize {
    CGSize(
      width: transform.offset.width + dragOffset.width,
      height: transform.offset.height + dragOffset.height)
  }

  /// Centres the graph on its start node, but only while the canvas is still where it
  /// started: once someone has panned or zoomed, their view is theirs.
  private func centreIfUntouched(
    in viewport: CGSize, content: CGSize, startNode: CGPoint?
  ) {
    guard transform == CanvasTransform(), viewport != .zero, content != .zero else {
      return
    }
    // The default view keeps cards readable (`defaultFitFloor`); ⌘9 is the deliberate
    // way to see a graph too big for that.
    var t = CanvasTransform.fitting(content, in: viewport, floor: CanvasTransform.defaultFitFloor)
    if let startNode {
      t.offset.height = (viewport.height / 2 - startNode.y) * t.scale
    }
    transform = t
  }

  /// The drawn graph itself, sized against the pane it's in. Split from `canvas` only to
  /// keep each function under the length limit.
  private func layers(_ derived: Derived) -> some View {
    let overview = derived.overview
    return GeometryReader { proxy in
      ZStack {
        bandsLayer(overview)
        startNodeLayer(overview)
        linksLayer(overview)
        loopsLayer(overview, reasons: derived.attentionReasons, now: now)
        // Above the cards and the links, since the handle it reveals hangs below the
        // origin dot and must not end up under a line drawn from it.
        entryHandleLayer(overview)
      }
      .scaleEffect(transform.scale)
      .offset(liveOffset)
      // Nothing has been panned yet, so first paint should put the graph where the eye
      // is rather than in the top-left corner with the lanes running off the bottom.
      .onAppear {
        viewport = proxy.size
        centreIfUntouched(in: proxy.size, content: overview.size, startNode: overview.startNode)
      }
      .onChange(of: proxy.size) { _, size in
        viewport = size
        centreIfUntouched(in: size, content: overview.size, startNode: overview.startNode)
      }
      // Folders arrive from the daemon after this view does, so the first paint has
      // nothing to centre on.
      .onChange(of: overview.size) { _, size in
        centreIfUntouched(in: viewport, content: size, startNode: overview.startNode)
      }
    }
  }

  private func canvas(_ derived: Derived) -> some View {
    layers(derived)
      .background {
        NotebookGrid(
          cellSize: NotebookGrid.defaultCellSize, offset: liveOffset, scale: transform.scale
        )
        .background(Theme.canvasBackground)
      }
      // On the full-pane view, not the layers' ZStack: with nothing to draw that stack
      // collapses to zero size in the GeometryReader's top-leading corner, which put
      // this overlay half under the sidebar instead of in the middle of the canvas.
      .overlay { emptyState(derived.overview) }
      .contentShape(Rectangle())
      .gesture(
        DragGesture()
          .onChanged { value in dragOffset = value.translation }
          .onEnded { value in
            transform.offset.width += value.translation.width
            transform.offset.height += value.translation.height
            dragOffset = .zero
          }
      )
      // Trackpad pinch, anchored where the fingers are: the graph under them stays put
      // while everything else moves around it, which is what makes zooming feel like
      // moving a sheet rather than like resizing a picture. `magnification` is relative to
      // the start of this gesture, so it multiplies the scale the pinch began at.
      .simultaneousGesture(
        MagnifyGesture()
          .onChanged { value in
            let base = pinchBaseScale ?? transform.scale
            pinchBaseScale = base
            transform = transform.zoomed(
              to: base * value.magnification, around: value.startLocation, in: viewport)
          }
          .onEnded { _ in pinchBaseScale = nil }
      )
      .background { CanvasScrollHandler(transform: $transform, viewport: viewport) }
  }

  private func zoomControls(_ overview: GraphOverview) -> some View {
    CanvasZoomControls(
      transform: $transform, viewport: viewport,
      content: overview.isEmpty ? .zero : overview.size)
  }

  /// The Graph row is always in the sidebar, so this view is what a fresh install lands
  /// on — before any folder has been opened there is nothing but the start marker and an
  /// empty lane, which looks identical to a canvas that failed to load. This says the
  /// graph is empty on purpose and puts the first step in it, the way `CanvasEmptyState`
  /// does for a project.
  ///
  /// Gated on the same `isEmpty` the start marker and zoom controls use, not on
  /// `loops.isEmpty`: a folder with no loops yet still draws its chip and tether, and
  /// this overlay used to appear on top of them — the canvas showing something and
  /// claiming to be empty at once, with an "Open Folder…" button for a folder that was
  /// already open. The chip's own "0 loops" is the empty state for that case.
  @ViewBuilder
  private func emptyState(_ overview: GraphOverview) -> some View {
    if overview.isEmpty {
      VStack(spacing: 10) {
        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
          .font(.system(size: 34))
          .foregroundStyle(.secondary)
        Text("Nothing running yet").font(.title3)
        Text("Loops from every folder you open show up here, wired to how they run.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 340)
        // The same panel the sidebar's Add Folder menu opens — its `fileImporter` is
        // bound to `welcome.isOpenPanelPresented`, so it doesn't matter who asks.
        Button("Open Folder…") { store.send(.welcome(.openFolderButtonTapped)) }
      }
      .padding(24)
    }
  }

  func open(_ loop: GraphOverview.Loop) {
    store.send(.projects(.element(id: loop.projectPath, action: .nodeTapped(loop.node.id))))
  }

  func folderName(_ path: String) -> String {
    store.projects[id: path]?.graph.project.name ?? "folder"
  }

}

#Preview {
  GraphOverviewView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
