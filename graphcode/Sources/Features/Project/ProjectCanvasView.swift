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

  @State private var canvasOffset: CGSize = .zero
  @State private var dragOffset: CGSize = .zero
  @State private var canvasScale: CGFloat = 1
  @State private var dragSourceID: UUID?
  @State private var dragLocation: CGPoint?

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
      newNodeForm
    }
    .sheet(item: $store.pendingEdge) { _ in
      edgeForm
    }
    // The delete confirmation is deliberately *not* here — it's hosted by `AppView`, so
    // it can also present for a deletion started from the sidebar while this canvas
    // isn't the visible detail pane. See `AppFeature.State.pendingLoopDeletion`.
  }

  private var canvas: some View {
    GeometryReader { _ in
      ZStack {
        startLayer
        edgesLayer
        nodesLayer
        dragPreview
      }
      .coordinateSpace(name: "canvas")
      .scaleEffect(canvasScale)
      .offset(
        CGSize(
          width: canvasOffset.width + dragOffset.width,
          height: canvasOffset.height + dragOffset.height))
    }
    .background {
      // Ruled like graph paper, and glued to the graph rather than to the window: the
      // rules pan and zoom with the nodes, so dragging empty space reads as moving the
      // sheet under you instead of nothing happening. See `NotebookGrid`.
      NotebookGrid(
        cellSize: Self.gridCellSize,
        offset: CGSize(
          width: canvasOffset.width + dragOffset.width,
          height: canvasOffset.height + dragOffset.height),
        scale: canvasScale
      )
      .background(Theme.canvasBackground)
    }
    .contentShape(Rectangle())
    .gesture(
      DragGesture()
        .onChanged { value in dragOffset = value.translation }
        .onEnded { value in
          canvasOffset.width += value.translation.width
          canvasOffset.height += value.translation.height
          dragOffset = .zero
        }
    )
    .simultaneousGesture(
      MagnificationGesture()
        .onChanged { value in canvasScale = max(0.4, min(2.5, value)) }
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
  private var startPosition: CGPoint? {
    let positions = store.graph.nodes.compactMap { store.nodePositions[$0.id] }
    guard let leftmost = positions.map(\.x).min(),
      let top = positions.map(\.y).min(),
      let bottom = positions.map(\.y).max()
    else { return nil }
    return CGPoint(x: leftmost - 150, y: (top + bottom) / 2)
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

  private func connectorHandle(for nodeID: UUID) -> some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 14, height: 14)
      .contentShape(Circle().inset(by: -8))  // bigger hit target than the visible dot
      .gesture(
        DragGesture(minimumDistance: 4, coordinateSpace: .named("canvas"))
          .onChanged { value in
            dragSourceID = nodeID
            dragLocation = value.location
          }
          .onEnded { value in
            if let targetID = hitTestNode(at: value.location, excluding: nodeID) {
              store.send(.edgeDrawn(from: nodeID, to: targetID))
            }
            dragSourceID = nil
            dragLocation = nil
          }
      )
  }

  /// Which node (if any) contains `point`, in "canvas"-space — approximate card frame,
  /// good enough for drop hit-testing without threading real card sizes through state.
  private func hitTestNode(at point: CGPoint, excluding: UUID) -> UUID? {
    for node in store.graph.nodes where node.id != excluding {
      guard let position = store.nodePositions[node.id] else { continue }
      let rect = CGRect(x: position.x - 110, y: position.y - 45, width: 220, height: 90)
      if rect.contains(point) { return node.id }
    }
    return nil
  }

  /// Shown on drop, before the edge is committed. The `?? pending` fallback in the
  /// binding never actually fires — the sheet only exists while `pendingEdge` is
  /// non-nil — it's just what lets a nested field bind without an optional dance.
  @ViewBuilder
  private var edgeForm: some View {
    if let pending = store.pendingEdge {
      EdgeSpecForm(
        pending: Binding(
          get: { store.pendingEdge ?? pending },
          set: { store.pendingEdge = $0 }
        ),
        fromTitle: nodeTitle(pending.from),
        toTitle: nodeTitle(pending.to),
        onCancel: { store.send(.cancelEdgeForm) },
        onCreate: { store.send(.createEdgeConfirmed) }
      )
    }
  }

  /// Same rollup the sidebar's monitor uses, scoped to this graph — one definition of
  /// "needs attention" rather than a canvas-flavoured second opinion.
  private func attentionReason(for node: LoopNode) -> AttentionReason? {
    store.attentionReasons[node.id]
  }

  private func nodeTitle(_ id: UUID) -> String {
    store.graph.nodes[id: id]?.title ?? "?"
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
