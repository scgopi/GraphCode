import SwiftUI

/// A canvas's origin dot — where a graph's entry points gather so the whole thing reads
/// as connected and has somewhere to be read from. Shared by `ProjectCanvasView` (one
/// folder's graph) and `GraphOverviewView` (the whole workspace).
///
/// A dot rather than a card: it isn't a loop, has no state, opens no terminal, and
/// nothing about it is clickable. It's the one thing on the canvas that stays the same
/// size and shape no matter what the graph is doing, which is what makes it read as the
/// origin instead of as another node.
///
/// **The caption is an overlay, not a stacked sibling.** Every caller places this with
/// `.position(origin)` and draws its tethers to that same `origin` — so this view's
/// layout size has to be the dot's size and nothing else. As a `VStack` of dot and label
/// it was the *stack* that got centred on the origin, which left the dot sitting about a
/// caption-half above the point every line actually converged on: the tethers met in
/// empty space below the dot. An overlay draws outside the frame without contributing to
/// it, so the dot alone is what gets centred.
struct StartMarker: View {
  var body: some View {
    dot
      .overlay(alignment: .bottom) {
        Text("Start")
          .font(.caption2)
          .foregroundStyle(.secondary)
          // Unbounded, so a caption wider than the dot isn't compressed to its width.
          .fixedSize()
          .offset(y: 15)
      }
      .allowsHitTesting(false)
  }

  private var dot: some View {
    Circle()
      .fill(Color.accentColor)
      .frame(width: 12, height: 12)
      // The ring keeps the dot legible where a tether passes behind it.
      .overlay(Circle().stroke(Theme.canvasBackground, lineWidth: 2))
      .padding(3)
      .overlay(Circle().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
  }
}

#Preview {
  // The crosshair is the point callers pass to `.position()`: the dot must sit on it,
  // because that is where every tether is drawn to.
  ZStack {
    Path {
      $0.move(to: CGPoint(x: 0, y: 50))
      $0.addLine(to: CGPoint(x: 100, y: 50))
      $0.move(to: CGPoint(x: 50, y: 0))
      $0.addLine(to: CGPoint(x: 50, y: 100))
    }
    .stroke(Color.red.opacity(0.5), lineWidth: 1)
    StartMarker().position(x: 50, y: 50)
  }
  .frame(width: 100, height: 100)
  .padding(40)
  .background(Theme.canvasBackground)
}
