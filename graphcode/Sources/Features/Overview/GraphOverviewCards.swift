import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// What the Graph view actually draws: the lines, the folder chips, and one card per
/// loop. Split out of `GraphOverviewView` purely for size — the same split
/// `NodeDraftForm` got out of `ProjectCanvasView`.
extension GraphOverviewView {
  var linksLayer: some View {
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

  var foldersLayer: some View {
    ForEach(overview.folders) { folder in
      folderChip(folder).position(folder.position)
    }
  }

  /// One card per loop, all of them clickable — a composite is drawn as the single loop
  /// it is, not expanded into its sub-graph. See `GraphOverview` for why.
  var loopsLayer: some View {
    ForEach(overview.loops) { loop in
      loopCard(loop).position(loop.position)
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
    .contentShape(Rectangle())
    // A folder chip goes to that folder's own canvas — where you can actually edit it.
    // The overview is for seeing the whole thing, not for rewiring it.
    .onTapGesture { store.send(.projectHeaderTapped(folder.path)) }
    .help(folder.path)
  }

  private func loopCard(_ loop: GraphOverview.Loop) -> some View {
    let node = loop.node
    let reason = attentionReasons[node.id]
    return VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(node.title).font(.headline).lineLimit(1)
        Spacer()
        Circle().fill(node.state.presenceColor).frame(width: 8, height: 8)
      }
      HStack(spacing: 4) {
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
        if node.backend != .claudeCode {
          Text(node.backend.displayName).font(.caption2).foregroundStyle(.tertiary)
        }
        if node.worktreeBinding != nil {
          Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.tertiary)
        }
      }
      CompositeBadge(node: node)
      if let reason {
        Label(reason.displayName, systemImage: "exclamationmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .frame(width: 220, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(
          reason == nil ? Color.secondary.opacity(0.3) : Color.orange,
          lineWidth: reason == nil ? 1 : 2)
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
