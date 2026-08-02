import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// A folder canvas's composites drawn open — the loops inside each `.proactive` node's
/// `subGraph`, stacked under the card that owns them. See `SubGraphLayout` for the
/// placement and for why sub-graphs live here rather than in the Graph view.
/// The layout itself is built once per body pass and passed in — see
/// `ProjectCanvasView.body` for why these don't compute their own.
extension ProjectCanvasView {
  /// Containment lines and the sub-graph's own edges, drawn under the chips.
  func subGraphLinksLayer(_ subGraph: SubGraphLayout) -> some View {
    ForEach(subGraph.links) { link in
      switch link.kind {
      case .edge(let kind, let fired):
        EdgeLineView(from: link.from, to: link.to, kind: kind, fired: fired)
      case .containment:
        // Fainter and shorter-dashed than any edge: containment is not a hand-off, and
        // nothing travels along it.
        Path {
          $0.move(to: link.from)
          $0.addLine(to: link.to)
        }
        .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
      }
    }
  }

  /// Siblings, not a nested stack — see `ProjectCanvasView.startLayer` for what a
  /// container does to `.position()` here.
  @ViewBuilder
  func subGraphChipsLayer(_ subGraph: SubGraphLayout) -> some View {
    ForEach(subGraph.placements) { placement in
      subGraphChip(placement).position(placement.position)
    }
    ForEach(subGraph.overflows) { overflow in
      overflowChip(overflow).position(overflow.position)
    }
  }

  /// One loop inside a composite. Smaller and dimmer than a card on purpose — it is part
  /// of the thing above it, not a peer of it — and inert: a node inside a `subGraph` is a
  /// template with no `zmx` session until the composite is piloted, so there is nothing
  /// for a tap to open.
  private func subGraphChip(_ placement: SubGraphLayout.Placement) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(placement.node.state.presenceColor.opacity(0.7))
        .frame(width: 5, height: 5)
      Text(placement.node.title).font(.caption).lineLimit(1)
      Spacer(minLength: 4)
      Text(placement.node.loopType.displayName).font(.caption2).foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .frame(width: 190 - CGFloat(placement.depth) * 14, alignment: .leading)
    .background(Theme.canvasTone.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
    .overlay(
      RoundedRectangle(cornerRadius: 6)
        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
    )
    .help("Inside this composite — a template, with no session until the composite is piloted")
  }

  /// What a composite is hiding, when its insides don't fit under its card.
  private func overflowChip(_ overflow: SubGraphLayout.Overflow) -> some View {
    Text("+\(overflow.hidden) more")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(Theme.canvasTone.opacity(0.92), in: Capsule())
      .overlay(Capsule().stroke(Color.secondary.opacity(0.2), lineWidth: 1))
      .help("Open this composite's own canvas to see all of it")
  }
}
