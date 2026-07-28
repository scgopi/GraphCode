import SwiftUI

/// What the graph canvas shows a project that has no loops yet.
///
/// A freshly added folder has a graph with nothing in it, and a blank canvas looks
/// identical to one that failed to load — the only affordance for the first loop is a
/// toolbar button you have to go looking for. This says the graph is empty on purpose
/// and puts the first step where the eye already is.
struct CanvasEmptyState: View {
  let projectName: String
  let onCreateLoop: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("No loops in \(projectName) yet").font(.title3)
      Text(
        "Create a loop to run an AI coding session in this folder, then drag between loops to hand work off."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 340)
      Button("Create Loop", action: onCreateLoop)
    }
    .padding(24)
  }
}

#Preview {
  CanvasEmptyState(projectName: "preview", onCreateLoop: {})
    .frame(width: 560, height: 420)
    .background(Theme.canvasBackground)
}
