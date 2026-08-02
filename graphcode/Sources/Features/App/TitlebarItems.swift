import GraphcodeKit
import SwiftUI

/// The titlebar's centred chip: how many loops want a human, and nothing else.
///
/// It used to carry standing counts of running and idle loops beside this one. They were
/// answers to a question nobody was asking: knowing five loops are running and four are
/// not is not something you act on, and both numbers are already legible from the cards,
/// the sidebar rows and the canvas rail — so the strip that is on screen in every pane
/// spent itself restating them. What is left is the only count that asks for something
/// back, and it is absent whenever the answer is zero.
///
/// The number is the same `AttentionRollup` the rail and the sidebar read; nothing here
/// rolls up twice.
struct NeedsYouChip: View {
  let count: Int

  var body: some View {
    // Bare chip: the toolbar's own glass capsule is the container, same as
    // `JumpFieldButton` — a second rounded rect around it doubled the chrome.
    HStack(spacing: 5) {
      StateIndicator(state: .awaitingInput, diameter: 6)
      Text("\(count) need you")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Self.ink)
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 8)
    .background(Self.tint, in: RoundedRectangle(cornerRadius: 5))
  }

  private static let tint = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.16)
  private static let ink = Color(red: 1.0, green: 0.745, blue: 0.361)  // #ffbe5c
}

/// The ⌘K affordance, in the titlebar where a search field belongs.
///
/// A shortcut nobody can see is a shortcut nobody uses. This is the discoverable half of
/// the jump palette — it opens exactly what ⌘K opens.
struct JumpFieldButton: View {
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    // No pill of its own: the toolbar already wraps the item in the system's glass
    // capsule, and a hand-drawn rounded rect inside it read as a button on a button.
    Button(action: action) {
      HStack(spacing: 8) {
        Text("Jump to loop")
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(isHovered ? 0.6 : 0.42))
        Text("⌘K")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
      }
      // The capsule is the toolbar's, so this padding is what sets its inset: at 2 the
      // text sat against the glass edge and the whole item read as cramped.
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help("Jump to a loop by name")
  }
}
