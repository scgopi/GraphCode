import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// A folder canvas's loop cards — what `ProjectCanvasView.nodesLayer` draws. Split out
/// of `ProjectCanvasView` purely for size, the same split `GraphOverviewCards` is for
/// the Graph view; the layers still land as siblings in the canvas's `ZStack`.
extension ProjectCanvasView {
  func nodesLayer(_ reasons: [UUID: AttentionReason]) -> some View {
    ForEach(store.graph.nodes) { node in
      // The hover that reveals a card's + handle lives in this per-card container,
      // not in canvas-level `@State`: up here a hover flip re-evaluated the whole
      // body — and with it `Derived`'s sub-graph walk and attention rollup, the exact
      // computation the comment on `body` exists to keep off the input path.
      HoverRevealingCard(isDragSource: dragSourceID == node.id) {
        nodeCard(for: node, reason: reasons[node.id])
      } handle: {
        connectorHandle(for: node.id)
      }
      .position(store.nodePositions[node.id] ?? .zero)
    }
  }

  /// One card plus its hover-revealed trailing handle, owning the hover state so a
  /// pointer crossing cards re-renders exactly the cards it crossed. The handle stays
  /// while hovered itself (it hangs half outside the card, so moving onto it must not
  /// count as leaving) and while a drag it started is in flight.
  private struct HoverRevealingCard<Card: View, Handle: View>: View {
    let isDragSource: Bool
    @ViewBuilder let card: () -> Card
    @ViewBuilder let handle: () -> Handle

    @State private var isHovered = false
    @State private var isHandleHovered = false

    var body: some View {
      card()
        .onHover { isHovered = $0 }
        .overlay(alignment: .trailing) {
          if isHovered || isHandleHovered || isDragSource {
            handle()
              .offset(x: 14)
              .onHover { isHandleHovered = $0 }
          }
        }
    }
  }

  /// What a card says, without the chrome around it — split from `nodeCard` only so
  /// each stays inside the function-length limit, as `loopCardBody` is on the overview.
  private func nodeCardBody(_ node: LoopNode, reason: AttentionReason?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(node.title).font(.headline).lineLimit(1)
        Spacer()
        Circle().fill(node.state.presenceColor).frame(width: 8, height: 8)
      }
      HStack(spacing: 4) {
        // Glyph carries the colour, text keeps its own ink — see `LoopTypeAppearance`.
        Image(systemName: node.loopType.glyph)
          .font(.caption2)
          .foregroundStyle(node.loopType.accent)
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
        if RemoteProjectLocation.parse(projectPath: store.graph.project.path) != nil {
          Image(systemName: "network")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      CompositeBadge(node: node)
      if let reason {
        Label(reason.displayName, systemImage: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
  }

  private func nodeCard(for node: LoopNode, reason: AttentionReason?) -> some View {
    nodeCardBody(node, reason: reason)
      .padding(10)
      .frame(width: 220, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      // The kind, readable before you read anything. A stripe rather than a tinted card:
      // the border is already spoken for by attention and the dot by state, so this is the
      // one channel on the card that was still free.
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
          .fill(node.loopType.accent)
          .frame(width: 4)
      }
      .clipShape(RoundedRectangle(cornerRadius: 10))
      // docs/06-ux-terminals.md#graph-canvas: nodes needing attention are distinguished on
      // the canvas itself, not only in the side panel — you should be able to tell from
      // the graph's shape where the problem is.
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(
            reason == nil ? Color.secondary.opacity(0.3) : Color.orange,
            lineWidth: reason == nil ? 1 : 2)
      )
      // Attention glows orange — the same channel as the stroke, thrown wider so it
      // reads at any zoom. See `cardGlow` for why elevation here is a glow at all.
      .cardGlow(reason == nil ? node.loopType.accent : .orange, emphasized: reason != nil)
      .contentShape(Rectangle())
      .onTapGesture { store.send(.nodeTapped(node.id)) }
      .contextMenu { nodeMenu(for: node) }
    // The hover-revealed + handle is `HoverRevealingCard`'s job — see `nodesLayer`.
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
    // Available on a resolved loop too: a finished loop is still something you read the
    // graph by, and its name is what you read.
    Button("Rename…") { store.send(.renameNodeRequested(node.id)) }
    if !node.isResolved {
      Button("Stop Loop") { store.send(.stopNodeTapped(node.id)) }
    }
    Divider()
    Button("Delete Loop…", role: .destructive) {
      store.send(.deleteNodeRequested(node.id))
    }
  }
}
