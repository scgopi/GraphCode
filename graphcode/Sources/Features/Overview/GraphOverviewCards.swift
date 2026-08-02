import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// What the Graph view actually draws: the lines, the folder chips, and one card per
/// loop. Split out of `GraphOverviewView` purely for size — the same split
/// `NodeDraftForm` got out of `ProjectCanvasView`.
/// The overview and the attention rollup are built once per body pass and passed in —
/// see `GraphOverviewView.Derived` for why these don't compute their own.
extension GraphOverviewView {
  func linksLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.links) { link in
      switch link.kind {
      case .edge(let kind, let fired):
        EdgeLineView(
          from: link.from, to: link.to, kind: kind, fired: fired, label: link.label)
      case .containment:
        // The overview never emits one — sub-graphs are expanded on a folder's own
        // canvas, not here — but the renderer covers every kind the shared type has.
        Path { path in
          path.move(to: link.from)
          path.addLine(to: link.to)
        }
        .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      }
    }
  }

  /// One band per open folder, drawn under everything. The band *is* the folder now —
  /// there is no chip and no tether, because a lane containing a project's loops says
  /// "these belong together" without a line drawn to explain it.
  func bandsLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.folders) { folder in
      CanvasBandView(
        rect: folder.band,
        name: folder.name,
        caption: folder.caption,
        glyph: folder.isGlobal ? "globe" : "folder.fill",
        entryPorts: folder.entryPorts,
        // A folder's caption goes to that folder's own canvas — where you can actually
        // edit it. The overview is for seeing the whole thing, not for rewiring it. The
        // global lane leads nowhere: this view already *is* it.
        onCaptionTapped: folder.isGlobal
          ? nil : { store.send(.projectHeaderTapped(folder.path)) }
      )
      .help(folder.isGlobal ? "Loops that belong to no folder" : folder.path)
    }
  }

  /// One card per loop, all of them clickable — a composite is drawn as the single loop
  /// it is, not expanded into its sub-graph. See `GraphOverview` for why.
  func loopsLayer(
    _ overview: GraphOverview, reasons: [UUID: AttentionReason], now: Date
  ) -> some View {
    ForEach(overview.loops) { loop in
      loopCard(loop, reason: reasons[loop.node.id], now: now).position(loop.position)
    }
  }

  /// The same `LoopCardView` a project's own canvas draws, so a loop reads identically
  /// wherever you meet it. Only the menu differs: from here a loop can be opened or
  /// revealed in its folder, but not rewired — see this view's own doc comment.
  private func loopCard(
    _ loop: GraphOverview.Loop, reason: AttentionReason?, now: Date
  ) -> some View {
    let node = loop.node
    return LoopCardView(
      node: node, reason: reason, now: now, entryRole: loop.entryRole,
      onPrimaryAction: { open(loop) },
      // The overview is read-only — rewiring happens on the folder's own canvas, which
      // is where you can see what you are rewiring. Both verbs go there.
      onWireUp: { store.send(.projectHeaderTapped(loop.projectPath)) },
      onMarkAsEntry: { store.send(.projectHeaderTapped(loop.projectPath)) }
    )
    .contentShape(Rectangle())
    .onTapGesture { open(loop) }
    .contextMenu {
      Button("Open Terminal") { open(loop) }
      Button("Reveal in \(folderName(loop.projectPath))") {
        store.send(.projectHeaderTapped(loop.projectPath))
      }
      if !node.isResolved {
        Divider()
        Button("Stop Loop", role: .destructive) {
          store.send(.stopNodeTapped(projectPath: loop.projectPath, nodeID: node.id))
        }
      }
    }
  }

}
