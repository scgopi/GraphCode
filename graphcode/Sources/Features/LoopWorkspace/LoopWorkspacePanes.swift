import GraphcodeKit
import SwiftUI

/// One node of a tab's split tree: a pane, or a row/column of nodes. Recursive, the way
/// the tree it draws is — a split whose child is itself a split is how ⌘D then ⌘⇧D gets
/// you a column inside a row.
///
/// `AnyLayout` rather than branching between `HStack` and `VStack`, and it exists for
/// this: it changes how children are arranged without changing what they *are*, so
/// flipping an axis doesn't recreate the panes on it. Each pane carries its own
/// `.id(ref.id)` (see `LoopWorkspaceView.surfaceView`), which is what pins the panes that
/// stay when a sibling appears or disappears beside them.
///
/// Rebuilding a pane is no longer the disaster it was when this drew at most two of them:
/// `TerminalSurfaceStore` owns the live terminals now, so a remounted pane borrows the
/// surface that is already running instead of freeing one and building another.
struct SplitTreeView<Pane: View>: View {
  let node: SplitNode
  let pane: (SurfaceRef) -> Pane

  var body: some View {
    switch node {
    case .leaf(let ref):
      pane(ref)
    case .split(let direction, let children):
      let layout =
        direction == .horizontal
        ? AnyLayout(HStackLayout(spacing: 0))
        : AnyLayout(VStackLayout(spacing: 0))
      layout {
        ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
          if index > 0 { Divider() }
          SplitTreeView(node: child, pane: pane)
        }
      }
    }
  }
}

/// One tab pill — fills the space its siblings leave it (matching a terminal app's
/// tab strip, not a browser's hug-the-title one), shows its ⌘-number by default and
/// swaps that for a close button on hover, and only the selected pill gets a lighter
/// fill so the strip reads as chrome with exactly one thing "showing" on it.
struct TabPillView: View {
  let title: String
  /// The loop's state, on the tab that actually runs it. `nil` on a plain shell.
  let state: LoopState?
  let isSelected: Bool
  let shortcutHint: String?
  let canClose: Bool
  let onSelect: () -> Void
  let onClose: () -> Void

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      if let state, state == .running || state.wantsHuman {
        StateIndicator(state: state, diameter: 5)
      }
      Text(title)
        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .lineLimit(1)
      if state == .awaitingInput {
        Text("asks")
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(.orange.opacity(0.9))
      }
      Spacer(minLength: 4)
      trailingGlyph
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    // One frame, not two. It used to cap the *content* at 220 and then stretch the pill
    // around it, which left the title and its ⌘-number floating in the middle of a wide
    // pill with dead space either side — and put the close button nowhere near the edge
    // you reach for. Stretching the content itself is what pins the trailing glyph to
    // the pill's own right edge.
    .frame(minWidth: 92, maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? Theme.tabSelectedBackground : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture(perform: onSelect)
    .onHover { isHovering = $0 }
  }

  @ViewBuilder
  private var trailingGlyph: some View {
    if canClose && isHovering {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    } else if let shortcutHint {
      Text(shortcutHint)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
  }
}
