import SwiftUI

/// The canvases' "make a new loop" affordance: a quiet + in system materials, shared
/// by the project canvas and the Graph overview so the two can't drift apart. Replaced
/// a filled accent pill — a canvas's create button should be findable at the top right,
/// not the loudest thing on the surface.
struct CanvasAddButton: View {
  let help: String
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(width: 28, height: 28)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help)
  }
}

#Preview {
  CanvasAddButton(help: "New Loop", action: {})
    .padding(24)
    .background(Theme.canvasBackground)
}
