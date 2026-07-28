import SwiftUI

/// A tab-strip control — split right, split down, new tab.
///
/// Lit from above like the strip it sits on (`Theme.tabBarGloss`), just a step
/// brighter, so it reads as a raised key rather than a glyph printed on the chrome.
/// Painted, not a system material, for the same reason the strip is: see `Theme`.
///
/// The hover brightening is the only feedback these have — they're icon-only, with no
/// label to change and no selected state to hold.
struct GlossyIconButton: View {
  let systemImage: String
  let help: String
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(isHovering ? Theme.controlGlossHovered : Theme.controlGloss)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Theme.controlBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { isHovering = $0 }
  }
}

#Preview {
  HStack(spacing: 4) {
    GlossyIconButton(systemImage: "rectangle.split.2x1", help: "Split right") {}
    GlossyIconButton(systemImage: "rectangle.split.1x2", help: "Split down") {}
    GlossyIconButton(systemImage: "plus", help: "New tab") {}
  }
  .padding()
  .background(Theme.tabBarGloss)
}
