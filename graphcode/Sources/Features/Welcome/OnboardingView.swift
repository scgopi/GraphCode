import SwiftUI

/// A first-launch primer on the app's vocabulary — loop, node, edge, and the four loop
/// types — shown once (see `AppFeature.State.showingOnboarding`) and reopenable from
/// the sidebar's help button. One scrollable card rather than a paged carousel: there
/// are six ideas to convey and a reader should be able to see them all, not click
/// through them.
struct OnboardingView: View {
  let onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 34))
          .foregroundStyle(Color.accentColor)
        Text("Welcome to GraphCode").font(.title2).bold()
        Text("Graphs of live, steerable AI coding sessions. Five words to know:")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 28)
      .padding(.bottom, 16)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          term(
            "circle.circle", "Loop",
            "A unit of work an AI coding agent runs in a real terminal session — one you "
              + "can open, watch, and steer mid-run. Loops keep running with the app closed.")
          term(
            "point.3.connected.trianglepath.dotted", "Node",
            "A loop as drawn on the graph canvas. Click a node to attach to its live "
              + "terminal — scrollback and all.")
          term(
            "arrow.right", "Edge",
            "A connection between loops, drawn by dragging between nodes: a hand-off "
              + "that fires when the source finishes, a message, or a spawn.")
          term(
            "flag.checkered", "Loop types",
            "Goal-based runs until a goal is met. Time-based repeats on a cadence in its "
              + "own prompt — watchers live here. Turn-based pauses for your review each "
              + "turn. Proactive is a group of loops run as one.")
          term(
            "bubble.left", "Quick Chat",
            "Just a conversation — no goal, no graph. The sidebar section above your "
              + "projects.")
          term(
            "folder", "Project",
            "A folder you add. It gets its own graph of loops; nothing is ever written "
              + "inside the folder itself.")
        }
        .padding(.horizontal, 28)
      }

      Button("Get Started") { onDismiss() }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .padding(.vertical, 20)
    }
    .frame(width: 480, height: 560)
  }

  private func term(_ glyph: String, _ name: String, _ explanation: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: glyph)
        .font(.body)
        .foregroundStyle(Color.accentColor)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(explanation).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

#Preview {
  OnboardingView(onDismiss: {})
}
