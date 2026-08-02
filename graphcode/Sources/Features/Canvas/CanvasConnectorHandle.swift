import SwiftUI

/// The `+` a card reveals on hover — "continue the graph from here". Just the dot and
/// its hit target; what a tap or a drag on it *means* belongs to the canvas that draws
/// it, since a folder's canvas can wire an edge to an existing loop and the Graph
/// overview can only create.
///
/// System materials, not accent fill — the same quiet treatment as `CanvasAddButton`,
/// and it only appears on hover anyway.
struct CanvasConnectorHandle: View {
  var body: some View {
    ZStack {
      Circle().fill(.regularMaterial)
      Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 1)
      Image(systemName: "plus")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.primary)
    }
    .frame(width: 14, height: 14)
    .contentShape(Circle().inset(by: -8))  // bigger hit target than the visible dot
  }
}

#Preview {
  CanvasConnectorHandle()
    .padding(24)
    .background(Theme.canvasBackground)
}
