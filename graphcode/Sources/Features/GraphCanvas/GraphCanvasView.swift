import ComposableArchitecture
import GraphcodeKit
import SwiftUI

struct GraphCanvasView: View {
  @Bindable var store: StoreOf<GraphCanvasFeature>

  @State private var canvasOffset: CGSize = .zero
  @State private var dragOffset: CGSize = .zero
  @State private var canvasScale: CGFloat = 1
  @State private var dragSourceID: UUID?
  @State private var dragLocation: CGPoint?

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if let connectionError = store.connectionError {
        Text("Not connected to graphcoded: \(connectionError)")
          .font(.caption)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .padding(6)
          .background(Color.red)
      }
      Divider()
      canvas
    }
    .frame(minWidth: 720, minHeight: 480)
    .task { await store.send(.task).finish() }
    .sheet(
      isPresented: Binding(
        get: { store.detail != nil },
        set: { isPresented in if !isPresented { store.send(.detailDismissed) } }
      )
    ) {
      if let detailStore = store.scope(state: \.detail, action: \.detail) {
        LoopNodeDetailView(store: detailStore)
      }
    }
    .sheet(isPresented: $store.showingNewNodeForm) {
      newNodeForm
    }
  }

  private var toolbar: some View {
    HStack {
      Text(store.graph.title).font(.headline)
      Spacer()
      Button {
        store.send(.addNodeButtonTapped)
      } label: {
        Label("New Node", systemImage: "plus.circle")
      }
    }
    .padding(10)
    .background(.bar)
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
    .background(Color(nsColor: .underPageBackgroundColor))
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
        EdgeLineView(from: from, to: to, fired: edge.fired)
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
        Circle().fill(color(for: node.state)).frame(width: 8, height: 8)
      }
      Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
      if node.state == .blocked {
        Label("Blocked", systemImage: "lock.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .frame(width: 220, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(node.state == .blocked ? Color.orange : Color.secondary.opacity(0.3))
    )
    .contentShape(Rectangle())
    .onTapGesture { store.send(.nodeTapped(node.id)) }
    .overlay(alignment: .trailing) {
      connectorHandle(for: node.id).offset(x: 14)
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

  private func color(for state: LoopState) -> Color {
    switch state {
    case .idle: .gray
    case .running: .blue
    case .awaitingInput: .orange
    case .blocked: .orange
    case .succeeded: .green
    case .failed: .red
    case .stalled: .purple
    }
  }

  private var newNodeForm: some View {
    VStack(spacing: 12) {
      Text("New Loop Node").font(.headline)
      Form {
        Picker("Type", selection: $store.draftLoopType) {
          Text("Turn-based").tag(LoopType.turnBased)
          Text("Time-based").tag(LoopType.timeBased)
        }
        .pickerStyle(.segmented)

        TextField("Title", text: $store.draftTitle)

        switch store.draftLoopType {
        case .turnBased:
          TextField("Check", text: $store.draftCheck)
        case .timeBased:
          TextField("Interval (seconds)", text: $store.draftIntervalSeconds)
          TextField("Prompt", text: $store.draftPrompt)
        case .goalBased, .proactive:
          EmptyView()
        }
      }
      HStack {
        Button("Cancel") { store.send(.cancelNewNodeForm) }
        Spacer()
        Button("Create") { store.send(.createNodeConfirmed) }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 360)
  }
}

/// A dashed line means the edge exists but its condition hasn't resolved yet (the
/// source node hasn't succeeded/failed); solid accent means `graphcoded` has already
/// fired it. There's no manual "Fire" affordance anymore — from Phase 3 on, firing is
/// automatic (see `graphcoded/Sources/GraphStore.swift`), so this view is read-only.
private struct EdgeLineView: View {
  let from: CGPoint
  let to: CGPoint
  let fired: Bool

  var body: some View {
    Path { path in
      path.move(to: from)
      path.addLine(to: to)
    }
    .stroke(
      fired ? Color.accentColor : Color.secondary,
      style: StrokeStyle(lineWidth: fired ? 2 : 1.5, dash: fired ? [] : [5, 4])
    )
  }
}

#Preview {
  GraphCanvasView(store: Store(initialState: GraphCanvasFeature.State()) { GraphCanvasFeature() })
}
