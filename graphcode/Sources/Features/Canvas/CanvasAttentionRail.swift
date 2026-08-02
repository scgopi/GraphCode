import GraphcodeKit
import SwiftUI

/// The canvas's top-left rail: how many loops want a human, how long the oldest has been
/// waiting, and a button that goes there.
///
/// Attention was *drawn* before this and not *reachable*. At fit zoom on a workspace of
/// three folders the only cue a loop was asking anything was a halo you had to pan-hunt
/// for, and the sidebar's list — the one surface that did say — is exactly where your
/// eyes are not while you are reading a graph. This puts the queue on the canvas, in
/// screen space, so it stays put while the graph moves under it.
///
/// **Fed, never derived.** The items come from the rollup the window already computed
/// once this body pass (`AppFeature.attentionItems` / `store.attentionReasons`); this
/// view must not roll its own, per the performance contract on both canvases' bodies.
/// It is also what stops the rail and the cards from disagreeing about who is asking.
struct CanvasAttentionRail: View {
  /// Already ordered by the rollup. Ordering for *review* is this view's own business —
  /// see `oldestFirst`.
  let items: [AttentionItem]
  let now: Date
  let onReview: () -> Void

  private var queue: [AttentionItem] { items.oldestFirst }

  var body: some View {
    if !items.isEmpty {
      HStack(spacing: 9) {
        StateIndicator(state: .awaitingInput, diameter: 7)
        Text(items.count == 1 ? "1 loop needs you" : "\(items.count) loops need you")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Self.ink)
        if let oldest = queue.first {
          Text("oldest \(LoopCardPresentation.duration(now.timeIntervalSince(oldest.createdAt)))")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Self.ink.opacity(0.55))
        }
        reviewButton
      }
      .padding(.leading, 11)
      .padding(.trailing, 6)
      .frame(height: 30)
      .background {
        RoundedRectangle(cornerRadius: 8)
          .fill(.ultraThinMaterial)
          .overlay { RoundedRectangle(cornerRadius: 8).fill(Self.tint.opacity(0.12)) }
          .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(Self.tint.opacity(0.3), lineWidth: 1)
          }
      }
      .padding(.leading, 20)
      .padding(.top, 18)
    }
  }

  private var reviewButton: some View {
    Button(action: onReview) {
      HStack(spacing: 5) {
        Text("Review").font(.system(size: 11, weight: .bold))
        Text("⌘⇧R").font(.system(size: 9.5, design: .monospaced)).opacity(0.75)
      }
      .foregroundStyle(Color(red: 0.141, green: 0.090, blue: 0.012))  // #241703
      .padding(.vertical, 3)
      .padding(.horizontal, 8)
      .background(Self.tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.plain)
    .help("Open the loop that has been waiting longest")
  }

  private static let tint = Color(red: 1.0, green: 0.624, blue: 0.039)  // #ff9f0a
  private static let ink = Color(red: 1.0, green: 0.804, blue: 0.478)  // #ffcd7a
}
