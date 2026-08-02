import GraphcodeKit
import SwiftUI

/// The titlebar's centred rollup: how many loops are running, how many want a human,
/// how many are doing nothing.
///
/// The window had no answer to "is anything happening" that didn't require looking at a
/// canvas. The sidebar's needs-you section is the queue and appears only when there *is*
/// one; this is the standing count, in the one strip that is on screen whatever pane you
/// are in — including a full-window terminal, which is where people spend most of their
/// time and where the graph is furthest away.
///
/// Counts come off the graphs the window already has. Nothing here rolls up twice, and
/// the needs-you number is the same `AttentionRollup` the rail and the sidebar read.
struct StatusRollupView: View {
  let graphs: [LoopGraph]
  let attention: Int

  /// Counted off `displayState`, like every card and dot, so the titlebar and the canvas
  /// cannot disagree about the same loop. Against raw `state` this number was every
  /// goal loop ever created and not yet resolved — which is the count of loops that
  /// *exist*, not of loops doing anything.
  var running: Int {
    graphs.reduce(0) { $0 + $1.nodes.count { $0.displayState == .running } }
  }

  /// Everything that isn't running and isn't asking. Deliberately one bucket: a titlebar
  /// that itemised `succeeded`/`stopped`/`blocked` would be a fourth place to read the
  /// same states the cards already spell out.
  var idle: Int {
    graphs.reduce(0) { total, graph in
      total + graph.nodes.count { $0.displayState != .running && !$0.displayState.wantsHuman }
    }
  }

  var body: some View {
    // Bare chips: the toolbar's own glass capsule is the container, same as
    // `JumpFieldButton` — a second rounded rect around them doubled the chrome.
    HStack(spacing: 4) {
      chip(count: running, label: "running", tint: Self.runningTint, ink: Self.runningInk)
      if attention > 0 {
        chip(
          count: attention, label: "need you", tint: Self.attentionTint,
          ink: Self.attentionInk)
      }
      chip(count: idle, label: "idle", tint: .clear, ink: .white.opacity(0.45))
    }
  }

  private func chip(count: Int, label: String, tint: Color, ink: Color) -> some View {
    HStack(spacing: 5) {
      StateIndicator(state: dotState(label), diameter: 6)
      Text("\(count) \(label)")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ink)
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 8)
    .background(tint, in: RoundedRectangle(cornerRadius: 5))
  }

  private func dotState(_ label: String) -> LoopState {
    switch label {
    case "running": .running
    case "need you": .awaitingInput
    default: .idle
    }
  }

  private static let runningTint = Color(red: 0.039, green: 0.518, blue: 1.0).opacity(0.16)
  private static let runningInk = Color(red: 0.486, green: 0.737, blue: 1.0)  // #7cbcff
  private static let attentionTint = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.16)
  private static let attentionInk = Color(red: 1.0, green: 0.745, blue: 0.361)  // #ffbe5c
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
