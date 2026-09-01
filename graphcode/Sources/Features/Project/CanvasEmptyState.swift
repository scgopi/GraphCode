import GraphcodeKit
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
  /// A few of the briefs the app ships with, offered as one-click starts. Empty
  /// everywhere but a folder's own empty canvas — see `StarterTemplates`.
  var starters: [PromptTemplate] = []
  var onStart: ((PromptTemplate) -> Void)?

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
  ///
  /// The starter row is the point of this state, not decoration: somebody who has
  /// never made a loop is being asked to pick one of five types, and three briefs
  /// they can actually start answer that better than any sentence about taxonomy.
  init(
    projectName: String, starters: [PromptTemplate] = [],
    onStart: ((PromptTemplate) -> Void)? = nil,
    onCreateLoop: @escaping () -> Void
  ) {
    self.init(
      symbol: "point.3.connected.trianglepath.dotted",
      title: "No loops in \(projectName) yet",
      message:
        "Create a loop to run an AI coding session in this folder, then drag between loops to hand work off.",
      actionTitle: "Create Loop",
      action: onCreateLoop)
    self.starters = starters
    self.onStart = onStart
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
      if !starters.isEmpty, let onStart {
        starterRow(onStart)
      }
    }
    .padding(24)
  }

  /// Three briefs, each labelled with the type it makes — the row is a taxonomy
  /// lesson that happens to also be a way to start working.
  private func starterRow(_ onStart: @escaping (PromptTemplate) -> Void) -> some View {
    VStack(spacing: 8) {
      Text("OR START FROM A TEMPLATE")
        .font(.system(size: 10, weight: .bold))
        .tracking(0.7)
        .foregroundStyle(.secondary.opacity(0.7))
        .padding(.top, 10)
      HStack(alignment: .top, spacing: 8) {
        ForEach(starters) { starter in
          Button {
            onStart(starter)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                  .fill((starter.shape ?? .sketch).accent)
                  .frame(width: 3, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                  Text(starter.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  Text(typeLabel(starter))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
              }
              Text(starter.summaryLine)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            }
            .padding(9)
            .frame(width: 168, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
              RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(starter.body)
        }
      }
    }
  }

  private func typeLabel(_ template: PromptTemplate) -> String {
    switch template.shape {
    case .sketch, nil: return "Main — stops when you close it"
    case .goalBased: return "Goal — stops when it's done"
    case .timeBased:
      let cadence = template.settings?.cadence?.lowercased() ?? ""
      return cadence.isEmpty ? "Timed — runs again" : "Timed · \(cadence)"
    case .turnBased: return "Turn — pauses for you"
    case .composite: return "Composite — a group of loops"
    }
  }
}

#Preview {
  CanvasEmptyState(
    projectName: "preview", starters: StarterTemplates.firstLaunchPicks, onStart: { _ in },
    onCreateLoop: {}
  )
  .frame(width: 560, height: 420)
  .background(Theme.canvasBackground)
}
