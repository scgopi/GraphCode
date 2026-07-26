import SwiftUI

/// Phase 0 placeholder. Replaced by the real root feature (graph canvas /
/// orchestrator monitor) starting Phase 1 — see docs/07-roadmap.md.
struct RootView: View {
  var body: some View {
    VStack(spacing: 12) {
      Text("Graphcode")
        .font(.largeTitle)
        .bold()
      Text("Empty app shell — Phase 0 scaffold.")
        .foregroundStyle(.secondary)
    }
    .padding(40)
    .frame(minWidth: 480, minHeight: 320)
  }
}

#Preview {
  RootView()
}
