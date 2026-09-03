import SwiftUI

/// The 22pt strip naming one pane and saying whether it has the keyboard.
///
/// Splitting a workspace produced two identical black rectangles, one of them veiled;
/// which was the agent and which was the shell you had opened to poke at something was a
/// thing you remembered rather than a thing you read. The veil says *which* pane is
/// inactive and nothing about what either of them is.
///
/// Additive: `Theme.unfocusedPaneVeil` still dims the pane below. This says the rest.
struct PaneHeaderView: View {
  let title: String
  let isFocused: Bool
  /// The shell or agent behind the pane — `claude`, `zsh`. Trailing, quiet.
  var detail: String?
  /// Whether this pane can be closed here — true for any pane of a split. A lone pane
  /// is its whole tab, and the tab strip's close button already speaks for it.
  var canClose: Bool
  var onClose: (() -> Void)?

  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isFocused ? Theme.paneFocusTint : Color.white.opacity(0.3))
        .frame(width: 5, height: 5)
      Text(title)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(isFocused ? Self.focusedInk : .white.opacity(0.45))
      if isFocused {
        Text("focused")
          .font(.system(size: 9.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.35))
      }
      Spacer(minLength: 6)
      trailing
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .frame(height: 22)
    .background(isFocused ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03))
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }

  /// The pane's own detail text, traded for an x while the header is hovered — the same
  /// swap the tab pill makes of its ⌘-number. Without it a split had panes that could
  /// only ever be closed by focus gymnastics, which is the hole #254 was filed through.
  @ViewBuilder
  private var trailing: some View {
    if canClose, isHovering, let onClose {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white.opacity(0.6))
      }
      .buttonStyle(.plain)
      .help("Close pane")
    } else {
      Text(isFocused ? (detail ?? "") : "⌘] to focus")
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.35))
    }
  }

  /// The blue lifted for text — the saturated tint is a dot colour, not an ink.
  private static let focusedInk =
    Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9)  // #8cc5ff
}
