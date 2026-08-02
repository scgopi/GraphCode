import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// A folder canvas's loop cards — what `ProjectCanvasView.nodesLayer` draws. Split out
/// of `ProjectCanvasView` purely for size, the same split `GraphOverviewCards` is for
/// the Graph view; the layers still land as siblings in the canvas's `ZStack`.
extension ProjectCanvasView {
  func nodesLayer(
    _ reasons: [UUID: AttentionReason], roles: [UUID: CardEntryRole], now: Date
  ) -> some View {
    ForEach(store.graph.nodes) { node in
      // The hover that reveals a card's + handle lives in this per-card container,
      // not in canvas-level `@State`: up here a hover flip re-evaluated the whole
      // body — and with it `Derived`'s sub-graph walk and attention rollup, the exact
      // computation the comment on `body` exists to keep off the input path.
      HoverRevealingCard(isDragSource: dragSourceID == node.id) {
        nodeCard(
          for: node, reason: reasons[node.id], role: roles[node.id] ?? .interior, now: now)
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

  /// The card itself is `LoopCardView`, shared with the Graph overview — see there for
  /// what it draws. What stays here is what only a project's own canvas has: the tap
  /// that opens the loop, the context menu, and the hover-revealed connector handle.
  private func nodeCard(
    for node: LoopNode, reason: AttentionReason?, role: CardEntryRole, now: Date
  ) -> some View {
    LoopCardView(
      node: node,
      reason: reason,
      now: now,
      isRemote: RemoteProjectLocation.parse(projectPath: store.graph.project.path) != nil,
      entryRole: role,
      onPrimaryAction: { store.send(.nodeTapped(node.id)) },
      // Starts the same edge drag the hover handle does, from this card.
      onWireUp: { dragSourceID = node.id },
      onMarkAsEntry: { store.send(.markAsEntryTapped(node.id)) }
    )
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
