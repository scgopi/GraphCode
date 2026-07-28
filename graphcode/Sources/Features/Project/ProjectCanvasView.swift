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
  /// One notebook square, in canvas points — a bit under half a node card's width, so a
  /// card spans a couple of squares and the ruling reads as scale rather than texture.
  private static let gridCellSize: CGFloat = 96

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
  /// The in-flight edge drag. Not `private` because `connectorHandle` — which sets
  /// them — lives in `ProjectCanvasForms.swift`, and Swift scopes `private` to a file.
  @State var dragSourceID: UUID?
  @State var dragLocation: CGPoint?

  var body: some View {
    VStack(spacing: 0) {
      if let connectionError = store.connectionError {
        Text("Not connected to graphcoded: \(connectionError)")
          .font(.caption)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(6)
          .background(Color.red)
      }
      canvas
        .overlay { emptyState }
        .overlay(alignment: .bottomTrailing) {
          CanvasZoomControls(transform: $transform, viewport: viewport, content: contentSize)
        }
    }
    .background(Theme.windowBackground)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addNodeButtonTapped)
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }
      // No folder header here on purpose. The canvas is only ever reached by picking a
      // project in the sidebar, which leaves that project's row selected in view — and
      // a second toolbar item would fuse into one pill with "New Node" anyway. The
      // header belongs on a loop's workspace, where the terminal fills the pane and the
      // project is no longer on screen; see `LoopWorkspaceView.folderHeader`.
    }
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
  private var contentSize: CGSize {
    let positions = store.graph.nodes.compactMap { store.nodePositions[$0.id] }
    guard let right = positions.map(\.x).max(), let bottom = positions.map(\.y).max() else {
      return .zero
    }
    let chipBottom = subGraph.placements.map(\.position.y).max() ?? 0
    return CGSize(width: right + 160, height: max(bottom, chipBottom) + 120)
  }

  /// Centres the graph, but only while the canvas is still where it started: once
  /// someone has panned or zoomed, their view is theirs and nothing here moves it.
  private func centreIfUntouched(in viewport: CGSize) {
    guard transform == CanvasTransform(), viewport != .zero, contentSize != .zero else {
      return
    }
    transform = .centred(contentSize, in: viewport)
  }

  private var canvas: some View {
    GeometryReader { proxy in
      ZStack {
        startLayer
        edgesLayer
        subGraphLinksLayer
        nodesLayer
        subGraphChipsLayer
        dragPreview
      }
      .coordinateSpace(name: "canvas")
      .scaleEffect(transform.scale)
      .offset(liveOffset)
      .onAppear {
        viewport = proxy.size
        centreIfUntouched(in: proxy.size)
      }
      .onChange(of: proxy.size) { _, size in
        viewport = size
        centreIfUntouched(in: size)
      }
      // The graph arrives from the daemon a beat after this view does, so the first
      // paint often has nothing to centre on. Re-centring when the content first has a
      // size is what puts the start marker — the leftmost thing on the canvas — on
      // screen instead of hard against the pane's left edge.
      .onChange(of: contentSize) { _, _ in centreIfUntouched(in: viewport) }
    }
    .background {
      // Ruled like graph paper, and glued to the graph rather than to the window: the
      // rules pan and zoom with the nodes, so dragging empty space reads as moving the
      // sheet under you instead of nothing happening. See `NotebookGrid`.
      NotebookGrid(
        cellSize: Self.gridCellSize, offset: liveOffset, scale: transform.scale
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
        store.send(.addNodeButtonTapped)
      }
    }
  }

  private var nodesLayer: some View {
    ForEach(store.graph.nodes) { node in
      nodeCard(for: node)
        .position(store.nodePositions[node.id] ?? .zero)
    }
  }

  /// The graph's origin: one dot every entry point hangs off, so the canvas reads as a
  /// connected graph with a beginning rather than as scattered cards.
  ///
  /// The tethers are deliberately quieter than any `EdgeLineView` — thinner, dimmer, no
  /// kind or fired state. They are not edges: nothing travels along them and there is
  /// nothing to right-click. Making them look like handoffs would be a lie about how
  /// the graph runs. See `LoopGraph.startAnchors` for which nodes get one.
  /// **Emits siblings — never wrap this in a container.** Every layer here is placed with
  /// `.position()`, which resolves against *its immediate parent's* frame. These views
  /// have to land directly in `canvas`'s `ZStack`, which fills the pane, so canvas
  /// coordinates and screen coordinates agree. Wrapping them in a `ZStack` of their own
  /// re-bases every one of them onto that inner stack's shrink-to-fit frame: the marker
  /// lands at its canvas coordinates measured from the middle of the pane, and the
  /// tethers are drawn to points that are no longer where the cards are — which reads as
  /// "the start node moved and its edges vanished".
  @ViewBuilder
  private var startLayer: some View {
    if let origin = startPosition {
      ForEach(store.graph.startAnchors, id: \.self) { anchorID in
        if let target = store.nodePositions[anchorID] {
          Path { path in
            path.move(to: origin)
            path.addLine(to: target)
          }
          .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
        }
      }
      StartMarker().position(origin)
    }
  }

  /// Left of the leftmost card and centred on the graph's vertical extent, so the
  /// tethers fan out rather than doubling back over the cards. Derived from the live
  /// positions instead of being a fixed point, so it stays put as the graph grows.
  ///
  /// Floored clear of the pane's left edge by `CanvasStart` — the grid lays its first
  /// column out at x=160, so the plain `leftmost - 150` this used to be put the marker
  /// at x=10 with half the dot and most of its caption clipped away, which is why the
  /// project canvas looked like it had no start node at all.
  private var startPosition: CGPoint? {
    CanvasStart.origin(of: store.graph.nodes.compactMap { store.nodePositions[$0.id] })
  }

  private var edgesLayer: some View {
    ForEach(store.graph.edges) { edge in
      if let from = store.nodePositions[edge.from], let to = store.nodePositions[edge.to] {
        EdgeLineView(from: from, to: to, kind: edge.kind, fired: edge.fired)
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

  private func nodeCard(for node: LoopNode) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(node.title).font(.headline).lineLimit(1)
        Spacer()
        Circle().fill(node.state.presenceColor).frame(width: 8, height: 8)
      }
      HStack(spacing: 4) {
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
        if node.backend != .claudeCode {
          // Only shown when it isn't the default — a badge on every card would be noise
          // in the overwhelmingly common single-backend graph.
          Text(node.backend.displayName).font(.caption2).foregroundStyle(.tertiary)
        }
        if node.worktreeBinding != nil {
          Image(systemName: "arrow.triangle.branch")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      CompositeBadge(node: node)
      if let reason = attentionReason(for: node) {
        Label(reason.displayName, systemImage: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .frame(width: 220, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    // docs/06-ux-terminals.md#graph-canvas: nodes needing attention are distinguished on
    // the canvas itself, not only in the side panel — you should be able to tell from
    // the graph's shape where the problem is.
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          attentionReason(for: node) == nil
            ? Color.secondary.opacity(0.3) : Color.orange,
          lineWidth: attentionReason(for: node) == nil ? 1 : 2)
    )
    .contentShape(Rectangle())
    .onTapGesture { store.send(.nodeTapped(node.id)) }
    .contextMenu { nodeMenu(for: node) }
    .overlay(alignment: .trailing) {
      connectorHandle(for: node.id).offset(x: 14)
    }
  }

  @ViewBuilder
  private func nodeMenu(for node: LoopNode) -> some View {
    Button("Open Terminal") { store.send(.nodeTapped(node.id)) }
    if node.loopType == .proactive {
      // Pilot always available (re-piloting a composite you've changed is normal);
      // arming only after a pilot, which is the docs/08 gate.
      Button("Pilot Once…") { store.send(.pilotCompositeTapped(node.id)) }
      Button("Arm Schedule") { store.send(.armCompositeTapped(node.id)) }
        .disabled(!node.pilotState.canArm)
    }
    if !node.isResolved {
      Button("Stop Loop") { store.send(.stopNodeTapped(node.id)) }
    }
    Divider()
    Button("Delete Loop…", role: .destructive) {
      store.send(.deleteNodeRequested(node.id))
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
