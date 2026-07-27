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
    .background(Theme.canvasBackground)
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

  private var nodesLayer: some View {
    ForEach(store.graph.nodes) { node in
      nodeCard(for: node)
        .position(store.nodePositions[node.id] ?? .zero)
    }
  }

  private var edgesLayer: some View {
    ForEach(store.graph.edges) { edge in
      if let from = store.nodePositions[edge.from], let to = store.nodePositions[edge.to] {
        EdgeLineView(from: from, to: to, kind: edge.kind, fired: edge.fired)
          .contextMenu {
            Text(edgeSummary(edge))
            Button("Delete Edge", role: .destructive) {
              store.send(.deleteEdgeTapped(edge.id))
            }
          }
      }
    }
  }

  private func edgeSummary(_ edge: LoopEdge) -> String {
    var parts = [edge.kind.displayName, edge.condition.displayName]
    if let transform = edge.payloadTransform.summary { parts.append(transform) }
    if let cycleGuard = edge.cycleGuard {
      // The pass count is the one thing you want at a glance on a running cycle.
      parts.append("loop \(edge.fireCount)/\(cycleGuard.summary)")
    }
    return parts.joined(separator: " · ")
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

/// Edges are drawn distinctly per `EdgeKind`, per
/// docs/06-ux-terminals.md#graph-canvas: a solid line for `.handoff`, a long-dashed
/// line for `.message`, a dotted line for `.spawn`. On top of that, a `.handoff` that
/// `graphcoded` hasn't fired yet is drawn dimmed and dashed — so "which relationship is
/// this" and "has it happened yet" stay two separate readings of the same line.
///
/// There's no manual "Fire" affordance — from Phase 3 on, firing is automatic (see
/// `GraphcodeKit/Sources/GraphStore.swift`), so this view is read-only.
/// A composite's card has to say how big the thing inside it is and whether it's live —
/// an armed routine that can spawn hundreds of agents shouldn't look identical to one
/// that has never run.
private struct CompositeBadge: View {
  let node: LoopNode

  @ViewBuilder
  var body: some View {
    if node.loopType == .proactive, let subGraph = node.subGraph {
      Label(
        "\(subGraph.nodes.count) loops · \(node.pilotState.displayName)",
        systemImage: node.pilotState == .armed ? "bolt.fill" : "bolt.slash"
      )
      .font(.caption2)
      .foregroundStyle(node.pilotState == .armed ? Color.accentColor : .secondary)
    }
  }
}

private struct EdgeLineView: View {
  let from: CGPoint
  let to: CGPoint
  let kind: EdgeKind
  let fired: Bool

  var body: some View {
    ZStack {
      // A 1.5pt dashed line is almost impossible to right-click. This invisible
      // fat stroke is the hit target; the visible line is drawn on top of it.
      line.stroke(Color.clear.opacity(0.001), style: StrokeStyle(lineWidth: 12))
        .contentShape(line.stroke(style: StrokeStyle(lineWidth: 12)))
      line.stroke(color, style: StrokeStyle(lineWidth: fired ? 2 : 1.5, dash: dashPattern))
    }
  }

  private var line: Path {
    Path { path in
      path.move(to: from)
      path.addLine(to: to)
    }
  }

  private var color: Color {
    switch kind {
    case .handoff: return fired ? Color.accentColor : Color.secondary
    case .message: return Color.teal
    case .spawn: return Color.purple
    }
  }

  private var dashPattern: [CGFloat] {
    switch kind {
    case .handoff: return fired ? [] : [5, 4]
    case .message: return [10, 5]
    case .spawn: return [2, 4]
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
