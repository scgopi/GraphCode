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
  @ViewBuilder
  private func nodeCard(
    for node: LoopNode, reason: AttentionReason?, role: CardEntryRole, now: Date
  ) -> some View {
    let card = LoopCardView(
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
    // A blocked card's pill says *that* it waits; hovering says on *what*, before a
    // click has to find out.
    if let waiting = blockedHelp(for: node) {
      card.help(waiting)
    } else {
      card
    }
  }

  private func blockedHelp(for node: LoopNode) -> String? {
    guard node.state == .blocked else { return nil }
    let upstream = store.canvasGraph.unfiredUpstreamTitles(of: node.id)
    guard !upstream.isEmpty else {
      return "Blocked — waiting on a hand-off that hasn't fired yet"
    }
    return "Blocked — waiting on "
      + upstream.map { "“\($0)”" }.joined(separator: " and ") + " to finish"
  }

  @ViewBuilder
  private func nodeMenu(for node: LoopNode) -> some View {
    Button("Open Terminal") { store.send(.nodeTapped(node.id)) }
    // The + handle's verb, findable where every other loop verb lives. Hidden on a
    // resolved loop: its hand-off edges have already fired, so a child created now
    // would wait on a parent that can never release it.
    if !node.isResolved {
      Button("New Child Loop…") { store.send(.newChildLoopTapped(node.id)) }
    }
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
    if node.loopType == .sketch {
      // The reason the type is worth having: a sketch that turned out to matter keeps
      // its session and gains a shape — each target asks for exactly one thing.
      Menu("Promote to…") {
        Section("Keep the session, add a shape") {
          Button("Goal — asks for a done check") {
            store.send(.promoteNodeRequested(node.id, to: .goalBased))
          }
          Button("Turn — asks where to pause") {
            store.send(.promoteNodeRequested(node.id, to: .turnBased))
          }
          Button("Timed — asks for a cadence") {
            store.send(.promoteNodeRequested(node.id, to: .timeBased))
          }
        }
      }
    }
    // Available on a resolved loop too: a finished loop is still something you read the
    // graph by, and its name is what you read.
    Button("Rename…") { store.send(.renameNodeRequested(node.id)) }
    // The design's first save entry point: a loop that worked is the most common thing
    // to reuse. Saving a shaped loop captures its type and settings alongside the text;
    // saving a Main loop captures text only. See PROMPT_TEMPLATES.md § Save as template.
    Button("Save as Template…") { store.send(.saveLoopTemplateTapped(node.id)) }
    if node.templateFollow != nil {
      // Detach converts it to a snapshot in place: the brief it already has keeps
      // running, and the next edit to the template's file stops reaching it.
      Button("Detach from Template") { store.send(.detachTemplateTapped(node.id)) }
    }
    if !node.isResolved {
      Button("Stop Loop") { store.send(.stopNodeTapped(node.id)) }
    }
    Divider()
    // Export packages this loop and everything descended from it — child loops,
    // sub-loops, session memory — into a zip another graph can import; Import splices
    // a bundle's loops in underneath this one. See `GraphExportBundle`. Behind the
    // experiments switch: a right-click verb that writes files and splices loops into
    // graphs is one a person should choose, not find.
    if SettingsModel.shared.settings.sharesLoops {
      Button("Export Loop…") { store.send(.exportNodeRequested(node.id)) }
      Button("Import Loops Here…") { store.send(.importLoopsRequested(asChildOf: node.id)) }
      Divider()
    }
    Button("Delete Loop…", role: .destructive) {
      store.send(.deleteNodeRequested(node.id))
    }
  }
}
