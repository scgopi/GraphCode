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
      Text(isFocused ? (detail ?? "") : "⌘] to focus")
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.35))
    }
    .lineLimit(1)
    .padding(.horizontal, 8)
    .frame(height: 22)
    .background(isFocused ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03))
  }

  /// The blue lifted for text — the saturated tint is a dot colour, not an ink.
  private static let focusedInk =
    Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9)  // #8cc5ff
}
