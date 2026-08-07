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
    ForEach(store.canvasGraph.nodes) { node in
      HoverRevealingCard(isDragSource: dragSourceID == node.id) {
        nodeCard(
          for: node, reason: reasons[node.id], role: roles[node.id] ?? .interior, now: now)
      } handle: {
        connectorHandle(for: node.id)
      }
      .position(store.nodePositions[node.id] ?? .zero)
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
      onMarkAsEntry: { store.send(.markAsEntryTapped(node.id)) },
      reclaimOffer: store.worktreeReclaimOffers[node.id],
      onReclaim: { store.send(.reclaimWorktreeTapped(node.id)) },
      onKeep: { store.send(.keepWorktreeTapped(node.id)) }
    )
    .contentShape(Rectangle())
    // A composite has no session of its own to open (`LoopNode.firstInstruction` is nil
    // for one), so the tap that opens a terminal everywhere else opens the group here —
    // otherwise clicking the card is the one gesture on the canvas that does nothing.
    .onTapGesture {
      store.send(node.loopType == .composite ? .compositeOpened(node.id) : .nodeTapped(node.id))
    }
    .contextMenu { nodeMenu(for: node) }
    // The hover-revealed + handle is `HoverRevealingCard`'s job — see `nodesLayer`.
  }

  @ViewBuilder
  private func nodeMenu(for node: LoopNode) -> some View {
    Button("Open Terminal") { store.send(.nodeTapped(node.id)) }
    if node.loopType == .composite {
      // First, because it is the step everything else depends on: a composite with
      // nothing inside can be piloted and armed and still do nothing at all.
      Button("Open Group") { store.send(.compositeOpened(node.id)) }
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
