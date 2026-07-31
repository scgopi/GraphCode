import SwiftUI

/// What a graph canvas shows when it has nothing on it yet.
///
/// A freshly added folder has a graph with nothing in it, and a blank canvas looks
/// identical to one that failed to load — the only affordance for the first loop is a
/// toolbar button you have to go looking for. This says the canvas is empty on purpose
/// and puts the first step where the eye already is.
///
/// Shared by every canvas that can be empty rather than copied per surface: the Quick
/// Chats canvas is as blank on day one as a folder's is, and two empty states that drift
/// apart would say the same thing two ways. Only the words and the glyph change — the
/// shape of "here is what this is, here is the one thing to do about it" doesn't.
struct CanvasEmptyState: View {
  let symbol: String
  let title: String
  let message: String
  let actionTitle: String
  let action: () -> Void

  init(
    symbol: String, title: String, message: String, actionTitle: String,
    action: @escaping () -> Void
  ) {
    self.symbol = symbol
    self.title = title
    self.message = message
    self.actionTitle = actionTitle
    self.action = action
  }

  /// A folder's canvas with no loops in it.
  init(projectName: String, onCreateLoop: @escaping () -> Void) {
    self.init(
      symbol: "point.3.connected.trianglepath.dotted",
      title: "No loops in \(projectName) yet",
      message:
        "Create a loop to run an AI coding session in this folder, then drag between loops to hand work off.",
      actionTitle: "Create Loop",
      action: onCreateLoop)
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text(title).font(.title3)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
      Button(actionTitle, action: action)
    }
    .padding(24)
  }
}

#Preview {
  CanvasEmptyState(projectName: "preview", onCreateLoop: {})
    .frame(width: 560, height: 420)
    .background(Theme.canvasBackground)
}
