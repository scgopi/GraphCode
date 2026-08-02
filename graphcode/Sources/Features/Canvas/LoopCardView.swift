import GraphcodeKit
import SwiftUI

/// The loop card, on both canvases.
///
/// One view rather than the two near-identical copies `ProjectCanvasCards` and
/// `GraphOverviewCards` each carried: they already drew the same thing, and the moment
/// the card started saying something — a state word, a live line, a trend — two copies
/// would have meant two versions of what a loop is doing, one of which is wrong.
///
/// **State first.** The kind used to have four channels (stripe, glyph, colour, label)
/// and the state had one 8pt dot. The stripe still carries the kind, because it is free
/// at any zoom, and everything with words in it now answers "what is this doing right
/// now" instead.
///
/// Takes `now` rather than reading the clock: elapsed labels on twenty cards must not be
/// twenty timers, and a `TimelineView` per card re-evaluates every card body on the tick
/// — on the canvas's gesture path. One `CanvasClock` tick per window, passed down.
struct LoopCardView: View {
  let node: LoopNode
  let reason: AttentionReason?
  let now: Date
  /// Drawn as a glyph rather than a word in the meta row, which is already full. The
  /// canvas knows this, the node doesn't — it is a property of where the project lives.
  var isRemote: Bool = false
  let onPrimaryAction: () -> Void

  enum Metrics {
    static let size = CGSize(width: 250, height: 106)
    static let radius: CGFloat = 11
    static let stripe: CGFloat = 4
  }

  /// The rollup decides, never the state on its own. A node blocked on an upstream that
  /// is still running is the graph working correctly — `AttentionRollup` deliberately
  /// leaves those out, and a card that warmed up for every `.blocked` node would put the
  /// canvas back to burying two real problems under fifteen normal ones. The card's
  /// *action* still follows the state: there is nothing to press about, only nothing to
  /// alarm about.
  private var needsAttention: Bool { reason != nil }

  var body: some View {
    let card = LoopCardPresentation(node: node, now: now)
    return VStack(alignment: .leading, spacing: 7) {
      titleRow
      liveLine(card.liveLine)
      detail(card.detail)
      Spacer(minLength: 0)
      metaRow(card.meta)
    }
    .padding(.top, 9)
    .padding(.horizontal, 11)
    .padding(.bottom, 10)
    .frame(width: Metrics.size.width, height: Metrics.size.height, alignment: .topLeading)
    .background(needsAttention ? Theme.loopCardAttention : Theme.loopCard)
    .overlay(alignment: .leading) {
      UnevenRoundedRectangle(
        topLeadingRadius: Metrics.radius, bottomLeadingRadius: Metrics.radius
      )
      .fill(node.loopType.accent)
      .frame(width: Metrics.stripe)
    }
    .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
    .overlay {
      RoundedRectangle(cornerRadius: Metrics.radius)
        .stroke(
          needsAttention ? Theme.loopCardAttentionBorder : Theme.loopCardBorder,
          lineWidth: 1)
    }
    .cardGlow(needsAttention ? .orange : node.loopType.accent, emphasized: needsAttention)
    // Attention arriving is not a layout change: the ring and the glow cross-fade so a
    // graph someone is reading doesn't jump under them.
    .animation(.easeInOut(duration: 0.2), value: needsAttention)
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(node.title)
        .font(.system(size: 14.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
        .lineLimit(1)
      Spacer(minLength: 4)
      LoopStatePill(state: node.state, loopType: node.loopType)
    }
  }

  /// What the loop was handed, in its own words. Mono because it is quoting a goal, a
  /// prompt, or a check — text the human wrote for a machine.
  @ViewBuilder
  private func liveLine(_ text: String?) -> some View {
    if let text {
      Text(text)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  @ViewBuilder
  private func detail(_ detail: LoopCardPresentation.Detail) -> some View {
    switch detail {
    case .none:
      EmptyView()
    case .progress(let progress):
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(progress.readings).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
          Spacer(minLength: 4)
          Text(progress.change).foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 10.5, design: .monospaced))
        ProgressTrack(fraction: progress.fraction, accent: node.loopType.accent)
      }
    case .action(let action):
      // The card's one button, and the reason a waiting loop shows no bar: there is no
      // progress to report, only something to do.
      Button(action: onPrimaryAction) {
        HStack(spacing: 5) {
          Text(action.title).font(.system(size: 11, weight: .bold))
          if let shortcut = action.shortcut {
            Text(shortcut).font(.system(size: 9, design: .monospaced)).opacity(0.7)
          }
        }
        .foregroundStyle(Color(red: 0.141, green: 0.090, blue: 0.012))  // #241703
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .background(
          Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.9),
          in: RoundedRectangle(cornerRadius: 5))
      }
      .buttonStyle(.plain)
    }
  }

  private func metaRow(_ parts: [String]) -> some View {
    HStack(spacing: 5) {
      // A drawn square rather than the kind's SF Symbol: the glyphs have wildly
      // different optical weights, and this row is a line of 10.5pt mono that a stack
      // glyph would tower over.
      RoundedRectangle(cornerRadius: 1.5)
        .fill(node.loopType.accent)
        .frame(width: 6, height: 6)
      Text(parts.joined(separator: " · "))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.52))
        .lineLimit(1)
        .truncationMode(.middle)
      if isRemote {
        Image(systemName: "network").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
      }
    }
  }
}

/// The state, in a word. The pill is the fix for the overloaded dot: colour, shape, and
/// text all say the same thing, so losing any one of them still leaves two.
struct LoopStatePill: View {
  let state: LoopState
  let loopType: LoopType

  var body: some View {
    HStack(spacing: 4) {
      StateIndicator(state: state)
      Text(state.displayWord(for: loopType))
        .font(.system(size: 10, weight: .bold))
        .tracking(0.2)
        .foregroundStyle(state.pillInk)
        .fixedSize()
    }
    .padding(.vertical, 2)
    .padding(.leading, 5)
    .padding(.trailing, 7)
    .background(state.pillFill, in: RoundedRectangle(cornerRadius: 5))
    .overlay {
      if let stroke = state.pillStroke {
        RoundedRectangle(cornerRadius: 5).stroke(stroke, lineWidth: 1)
      }
    }
  }
}

/// The dot — filled, or a ring for the states that are present without producing
/// anything. Pulses only while running, so the one thing moving on the canvas is the one
/// thing changing under you.
struct StateIndicator: View {
  let state: LoopState
  var diameter: CGFloat = 6

  @State private var dimmed = false

  var body: some View {
    indicator
      .frame(width: diameter, height: diameter)
      .opacity(dimmed ? 0.35 : 1)
      .animation(
        state.pulses
          ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
          : .default,
        value: dimmed
      )
      .onAppear { dimmed = state.pulses }
      .onChange(of: state.pulses) { _, pulses in dimmed = pulses }
  }

  @ViewBuilder
  private var indicator: some View {
    if state.indicatorIsHollow {
      Circle().strokeBorder(state.indicatorTint, lineWidth: 1.5)
    } else {
      Circle().fill(state.indicatorTint)
    }
  }
}

/// The 3pt progress track. Its own view so an empty history draws nothing at all rather
/// than a zero-width fill — see `LoopCardPresentation.Detail`.
private struct ProgressTrack: View {
  let fraction: Double
  let accent: Color

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.09))
        Capsule().fill(accent).frame(width: proxy.size.width * min(max(fraction, 0), 1))
      }
    }
    .frame(height: 3)
  }
}
