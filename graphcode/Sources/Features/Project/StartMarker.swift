import SwiftUI

/// The graph canvas's origin dot — where `ProjectCanvasView` gathers the graph's entry
/// points so the whole thing reads as connected and has somewhere to be read from.
///
/// A dot rather than a card: it isn't a loop, has no state, opens no terminal, and
/// nothing about it is clickable. It's the one thing on the canvas that stays the same
/// size and shape no matter what the graph is doing, which is what makes it read as the
/// origin instead of as another node.
struct StartMarker: View {
  var body: some View {
    VStack(spacing: 5) {
      Circle()
        .fill(Color.accentColor)
        .frame(width: 12, height: 12)
        // The ring keeps the dot legible where a tether passes behind it.
        .overlay(Circle().stroke(Theme.canvasBackground, lineWidth: 2))
        .padding(3)
        .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
      Text("Start")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .allowsHitTesting(false)
  }
}

#Preview {
  StartMarker()
    .padding(40)
    .background(Theme.canvasBackground)
}
