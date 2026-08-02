import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// One project's pan/zoom graph canvas — the detail-pane content `AppView` shows when
/// a project is selected and no node's terminal is open. Renamed from Phase 4's
/// `ProjectView` in the multi-project sidebar follow-up (docs/07-roadmap.md#phase-4
/// --projects): the `NavigationSplitView` shell, the "‹ Projects" button, and the
/// detail-vs-canvas branching all moved up to `AppView`/`AppFeature`, since a shared
/// sidebar and detail pane across several open projects isn't this view's concern
/// anymore — this is now just the canvas itself, still scoped to one project's store.
///
/// The "New Node" toolbar button and its sheet stay together here rather than moving to
/// the sidebar: this view only renders while its project's canvas is the visible detail
/// content, so the button is naturally unavailable while a node's terminal is showing
/// instead — no separate enablement logic needed.
struct ProjectCanvasView: View {
  @Bindable var store: StoreOf<ProjectFeature>

  /// Where this canvas is looking. Shared with the Graph overview — see
  /// `CanvasTransform` for why the scale and offset are one value with arithmetic on it
  /// rather than two numbers the gestures nudge.
  @State private var transform = CanvasTransform()
  @State private var dragOffset: CGSize = .zero
  /// The scale the current pinch started from. `MagnifyGesture.magnification` is
  /// relative to the start of *that* gesture, so without a captured baseline every new
  /// pinch would snap the canvas back to 1× before it moved anywhere.
  @State private var pinchBaseScale: CGFloat?
  @State private var viewport: CGSize = .zero
  /// What the cards' elapsed labels are measured against, advanced by the window's one
  /// 30-second tick — see `CanvasClock`.
  @State private var now = Date()
  /// The in-flight edge drag. Not `private` because `connectorHandle` — which sets
  /// them — lives in `ProjectCanvasForms.swift`, and Swift scopes `private` to a file.
  @State var dragSourceID: UUID?
  @State var dragLocation: CGPoint?

  /// The canvas's derived values, computed once per body pass — see `body`.
  struct Derived {
    let subGraph: SubGraphLayout
    /// The queue, for the rail. The cards' tints come off the same list — one rollup,
    /// read twice, so the rail can never name a loop the cards don't mark.
    let attentionItems: [AttentionItem]
    let attentionReasons: [UUID: AttentionReason]
    /// Where each loop sits in "where does the graph begin" — one walk of the edge list
    /// for the whole canvas rather than one per card.
    let entryRoles: [UUID: CardEntryRole]

    init(
      subGraph: SubGraphLayout, attentionItems: [AttentionItem],
      entryRoles: [UUID: CardEntryRole]
    ) {
      self.subGraph = subGraph
      self.attentionItems = attentionItems
      self.entryRoles = entryRoles
      attentionReasons = Dictionary(
        attentionItems.map { ($0.nodeID, $0.reason) }, uniquingKeysWith: { first, _ in first })
    }
  }

  /// Everything the canvas draws that is *derived* from the store rather than stored in
  /// it, built exactly once per body pass and handed down to the layers.
  ///
  /// This is a performance contract, not a style choice. `SubGraphLayout` walks every
  /// composite's sub-graph recursively and `attentionReasons` rolls the whole graph up,
  /// and both used to be computed properties the layers read directly — so one body pass
  /// built the sub-graph layout five times over, and `attentionReason(for:)` re-rolled the
  /// entire graph three times *per card*, which is quadratic in the number of loops. A pan
  /// re-evaluates this body on every pointer event, so all of that landed on the main
  /// thread at gesture rate. Read each derived value once, here, and pass it along.
  var body: some View {
    let derived = Derived(
      subGraph: SubGraphLayout(nodes: store.graph.nodes, positions: store.nodePositions),
      attentionItems: store.attentionItems,
      entryRoles: CardEntryRole.roles(
        in: store.graph, declaredEntries: store.declaredEntryIDs))

    return VStack(spacing: 0) {
      if let connectionError = store.connectionError {
        Text("Not connected to graphcoded: \(connectionError)")
          .font(.caption)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(6)
          .background(Color.red)
      }
      canvas(derived)
        .overlay { emptyState }
        .overlay(alignment: .bottomTrailing) {
          CanvasZoomControls(
            transform: $transform, viewport: viewport, content: contentSize(derived.subGraph))
        }
        // On the canvas itself, top-right, rather than in the window toolbar: up there
        // it fused into one grey pill with the system chrome and read as furniture.
        // A quiet + in system materials, not a filled accent pill — HIG-style: the
        // affordance should be findable, not the loudest thing on the canvas.
        .overlay(alignment: .topTrailing) {
          CanvasAddButton(help: "New Loop") {
            store.send(.addNodeButtonTapped(parentBackend: nil))
          }
          .padding(.trailing, 20)
          .padding(.top, 18)
        }
        // In screen space, so the queue stays put while the graph pans under it. Fed the
        // rollup this body already derived — never its own; see `body`.
        .overlay(alignment: .topLeading) {
          CanvasAttentionRail(items: derived.attentionItems, now: now) {
            store.send(.reviewAttentionTapped)
          }
        }
    }
    .background(Theme.windowBackground)
    .onReceive(CanvasClock.tick) { now = $0 }
    // No folder header in the toolbar on purpose. The canvas is only ever reached by
    // picking a project in the sidebar, which leaves that project's row selected in
    // view. The header belongs on a loop's workspace, where the terminal fills the
    // pane and the project is no longer on screen; see `LoopWorkspaceView.folderHeader`.
    .sheet(isPresented: $store.showingNewNodeForm) {
      NodeDraftForm(store: store)
    }
    .sheet(item: $store.pendingEdge) { _ in
      edgeForm
    }
    // The delete confirmation is deliberately *not* here — it's hosted by `AppView`, so
    // it can also present for a deletion started from the sidebar while this canvas
    // isn't the visible detail pane. See `AppFeature.State.pendingLoopDeletion`.
  }

  /// Scale and offset as the canvas is currently drawn — the committed transform plus
  /// whatever the in-flight pan has moved so far.
  private var liveOffset: CGSize {
    CGSize(
      width: transform.offset.width + dragOffset.width,
      height: transform.offset.height + dragOffset.height)
  }

  /// How much room the graph takes up, for actual-size and fit. Measured out to the far
  /// edge of the furthest card rather than to its centre, so fitting doesn't crop the
  /// thing it was asked to fit.
  ///
  /// Takes the already-built sub-graph layout rather than reaching for one: see `body`.
  func contentSize(_ subGraph: SubGraphLayout) -> CGSize {
    let positions = store.graph.nodes.compactMap { store.nodePositions[$0.id] }
    guard let right = positions.map(\.x).max(), let bottom = positions.map(\.y).max() else {
      return .zero
    }
    let chipBottom = subGraph.placements.map(\.position.y).max() ?? 0
    return CGSize(width: right + 160, height: max(bottom, chipBottom) + 120)
  }

  /// Centres the graph, but only while the canvas is still where it started: once
  /// someone has panned or zoomed, their view is theirs and nothing here moves it.
  private func centreIfUntouched(in viewport: CGSize, content: CGSize) {
    guard transform == CanvasTransform(), viewport != .zero, content != .zero else {
      return
    }
    transform = .centred(content, in: viewport)
  }

  private func canvas(_ derived: Derived) -> some View {
    let content = contentSize(derived.subGraph)
    return GeometryReader { proxy in
      ZStack {
        bandLayer(derived)
        edgesLayer
        subGraphLinksLayer(derived.subGraph)
        nodesLayer(derived.attentionReasons, roles: derived.entryRoles, now: now)
        subGraphChipsLayer(derived.subGraph)
        dragPreview
      }
      .coordinateSpace(name: "canvas")
      .scaleEffect(transform.scale)
      .offset(liveOffset)
      .onAppear {
        viewport = proxy.size
        centreIfUntouched(in: proxy.size, content: content)
      }
      .onChange(of: proxy.size) { _, size in
        viewport = size
        centreIfUntouched(in: size, content: content)
      }
      // The graph arrives from the daemon a beat after this view does, so the first
      // paint often has nothing to centre on. Re-centring when the content first has a
      // size is what puts the start marker — the leftmost thing on the canvas — on
      // screen instead of hard against the pane's left edge.
      .onChange(of: content) { _, size in centreIfUntouched(in: viewport, content: size) }
    }
    .background {
      // Ruled like graph paper, and glued to the graph rather than to the window: the
      // rules pan and zoom with the nodes, so dragging empty space reads as moving the
      // sheet under you instead of nothing happening. See `NotebookGrid`.
      NotebookGrid(
        cellSize: NotebookGrid.defaultCellSize, offset: liveOffset, scale: transform.scale
      )
      .background(Theme.canvasBackground)
    }
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
    // Trackpad pinch, anchored where the fingers are, exactly as on the Graph overview —
    // `magnification` is relative to the start of this gesture, so it multiplies the
    // scale the pinch began at rather than replacing it.
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
  }

  /// Drawn as an overlay rather than as a branch on `canvas` so panning and zooming
  /// stay live underneath: `CanvasEmptyState` fills no hit-testable shape, so drags on
  /// the surrounding space still reach the canvas gesture.
  @ViewBuilder
  private var emptyState: some View {
    if store.graph.nodes.isEmpty {
      CanvasEmptyState(projectName: store.graph.project.name) {
        store.send(.addNodeButtonTapped(parentBackend: nil))
      }
    }
  }

  // `nodesLayer` — the loop cards, their hover-revealed handles, and their context
  // menu — lives in `ProjectCanvasCards.swift`, split out for size the way the Graph
  // view's cards are in `GraphOverviewCards.swift`.

  /// The band the folder's cards sit in — one, unlabelled, since a project's own canvas
  /// is already entirely that project and a caption naming it would be the pane telling
  /// you where you are.
  ///
  /// This replaced the start marker and its tethers. The marker's job was making a
  /// scatter read as a graph; a band does that with the space the cards already occupy,
  /// and it costs no ink in the canvas's most legible column.
  ///
  /// **Emits a sibling — never wrap this in a container.** Every layer here is placed
  /// with `.position()`, which resolves against *its immediate parent's* frame. These
  /// views have to land directly in `canvas`'s `ZStack`, which fills the pane, so canvas
  /// coordinates and screen coordinates agree. An inner `ZStack` re-bases them onto its
  /// own shrink-to-fit frame, and the band lands somewhere the cards are not.
  @ViewBuilder
  private func bandLayer(_ derived: Derived) -> some View {
    if let rect = bandRect {
      CanvasBandView(rect: rect, entryPorts: entryPorts(derived))
    }
  }

  /// The leading-edge port of everything nothing hands off to — roots and loose loops
  /// alike, so the lane's origin reaches every card that would otherwise float.
  private func entryPorts(_ derived: Derived) -> [CGPoint] {
    store.graph.nodes.compactMap { node in
      let role = derived.entryRoles[node.id]
      guard role == .entry || role == .unwired,
        let centre = store.nodePositions[node.id]
      else { return nil }
      return CGPoint(x: centre.x - LoopCardView.Metrics.size.width / 2, y: centre.y)
    }
  }

  /// Around every card, or `nil` for an empty canvas — a band around nothing is a
  /// rectangle on a blank pane, and `CanvasEmptyState` is already explaining that.
  private var bandRect: CGRect? {
    CanvasBand.rect(
      around: store.graph.nodes.compactMap { store.nodePositions[$0.id] },
      cardSize: LoopCardView.Metrics.size,
      captioned: false)
  }

  private var edgesLayer: some View {
    ForEach(store.graph.edges) { edge in
      if let from = store.nodePositions[edge.from], let to = store.nodePositions[edge.to] {
        EdgeLineView(
          from: from, to: to, kind: edge.kind, fired: edge.fired, label: edge.cycleLabel
        )
        .contextMenu {
          Text(edge.canvasSummary)
          Button("Delete Edge", role: .destructive) {
            store.send(.deleteEdgeTapped(edge.id))
          }
        }
      }
    }
  }

  @ViewBuilder
  private var dragPreview: some View {
    if let dragSourceID, let dragLocation, let source = store.nodePositions[dragSourceID] {
      Path { path in
        path.move(to: source)
        path.addLine(to: dragLocation)
      }
      .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4]))
    }
  }

}

#Preview {
  ProjectCanvasView(
    store: Store(
      initialState: ProjectFeature.State(
        graph: LoopGraph(project: ProjectRef(path: "/tmp/preview", name: "preview"))
      )
    ) { ProjectFeature() }
  )
}
