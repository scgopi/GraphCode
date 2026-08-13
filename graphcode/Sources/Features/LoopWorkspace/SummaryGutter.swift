import GraphcodeKit
import SwiftUI

/// The 26pt strip left at the window's right edge when the rail is hidden.
///
/// Hiding the rail gives the terminal the width back; it should not make the loop
/// unobservable. What survives is the smallest honest thing: the loop's state dot, the
/// word `SUMMARY` on its side, and the current beat on hover.
///
/// **Hiding never hides the ask.** When the loop wants a human the gutter turns amber and
/// names it in one word. The card, the sidebar and the titlebar chip are unaffected either
/// way — attention was never this section's job to report, which is why the colour here is
/// read off `displayState` and not off the summary.
struct SummaryGutter: View {
  let node: LoopNode
  let now: Date
  let onTapped: () -> Void

  static let width: CGFloat = 26

  private var wantsHuman: Bool { node.displayState.wantsHuman }

  private var label: String { wantsHuman ? "ASKS YOU" : "SUMMARY" }

  private var tint: Color {
    wantsHuman ? BeatKindAppearance.dot(.asking) : Theme.paneFocusTint
  }

  var body: some View {
    VStack(spacing: 10) {
      Circle().fill(tint).frame(width: 6, height: 6)
      Text(label)
        .font(.system(size: 10.5, weight: .bold))
        .tracking(1.05)
        .foregroundStyle(
          wantsHuman
            ? BeatKindAppearance.ink(.asking) : Color.white.opacity(0.58)
        )
        .fixedSize()
        .rotationEffect(.degrees(90))
        .frame(width: 12)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .frame(width: Self.width)
    .frame(maxHeight: .infinity)
    .background(wantsHuman ? BeatKindAppearance.dot(.asking).opacity(0.14) : Theme.workspaceRail)
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(wantsHuman ? BeatKindAppearance.dot(.asking).opacity(0.4) : .white.opacity(0.07))
        .frame(width: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onTapped)
    // Hover peeks at the current beat. A tooltip rather than a popover: the gutter exists
    // because someone wanted the width back, and a panel that springs out of it on hover
    // would take it again.
    .help(hoverText)
  }

  private var hoverText: String {
    let presentation = LoopSummaryPresentation(node: node, now: now)
    guard !presentation.text.isEmpty else { return "Show the summary rail (⌥G)" }
    return "\(presentation.text) — ⌥G to show the rail"
  }
}
