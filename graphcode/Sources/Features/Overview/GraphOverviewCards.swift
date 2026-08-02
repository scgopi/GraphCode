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
        EdgeLineView(from: link.from, to: link.to, kind: kind, fired: fired)
      case .tether:
        // Quieter than any edge, and deliberately so: nothing travels along a tether.
        // Same reasoning as `ProjectCanvasView.startLayer`.
        line(link).stroke(Color.secondary.opacity(0.35), lineWidth: 1)
      case .containment:
        // The overview never emits one — sub-graphs are expanded on a folder's own
        // canvas, not here — but the renderer covers every kind the shared type has.
        line(link).stroke(
          Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      }
    }
  }

  private func line(_ link: GraphOverview.Link) -> Path {
    Path { path in
      path.move(to: link.from)
      path.addLine(to: link.to)
    }
  }

  func foldersLayer(_ overview: GraphOverview) -> some View {
    ForEach(overview.folders) { folder in
      folderChip(folder).position(folder.position)
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

  private func folderChip(_ folder: GraphOverview.Folder) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "folder.fill").foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(folder.name).font(.callout).lineLimit(1)
        Text(folder.loopCount == 1 ? "1 loop" : "\(folder.loopCount) loops")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(width: 190, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
    )
    // A folder has no loop kind to tint with, so the default neutral lift — see
    // `cardGlow`.
    .cardGlow()
    .contentShape(Rectangle())
    // A folder chip goes to that folder's own canvas — where you can actually edit it.
    // The overview is for seeing the whole thing, not for rewiring it.
    .onTapGesture { store.send(.projectHeaderTapped(folder.path)) }
    .help(folder.path)
  }

  /// The same `LoopCardView` a project's own canvas draws, so a loop reads identically
  /// wherever you meet it. Only the menu differs: from here a loop can be opened or
  /// revealed in its folder, but not rewired — see this view's own doc comment.
  private func loopCard(
    _ loop: GraphOverview.Loop, reason: AttentionReason?, now: Date
  ) -> some View {
    let node = loop.node
    return LoopCardView(node: node, reason: reason, now: now) { open(loop) }
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
