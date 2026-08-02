import SwiftUI

/// The canvases' "make a new loop" affordance, shared by the project canvas and the
/// Graph overview so the two can't drift apart.
///
/// Quiet, at the canvas's top right — a create button should be findable, not the
/// loudest thing on the surface. It carries its word rather than only a `+`: at 30pt
/// tall the label costs nothing, and an icon-only button on a canvas whose other corner
/// now holds a labelled attention rail read as an unexplained glyph.
struct CanvasAddButton: View {
  let help: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Text(verbatim: "+").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
        Text(help).font(.system(size: 12, weight: .semibold))
      }
      .foregroundStyle(.white.opacity(isHovered ? 0.9 : 0.72))
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background {
        RoundedRectangle(cornerRadius: 8)
          .fill(.ultraThinMaterial)
          .overlay {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isHovered ? 0.1 : 0.06))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.09), lineWidth: 1)
          }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
  }
}

#Preview {
  CanvasAddButton(help: "New Loop", action: {})
    .padding(24)
    .background(Theme.canvasBackground)
}
