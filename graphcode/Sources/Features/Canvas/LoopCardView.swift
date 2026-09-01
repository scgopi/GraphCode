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
  /// Where this loop sits in the question "where does the graph begin" — see
  /// `CardEntryRole`. Comes off `LoopGraph`, which is the only thing that can answer it.
  var entryRole: CardEntryRole = .interior
  let onPrimaryAction: () -> Void
  /// The two verbs an unwired loop offers. Nothing else on the card uses them.
  var onWireUp: (() -> Void)?
  var onMarkAsEntry: (() -> Void)?
  /// The resolve moment's offer, when this folder's policy is "Ask me" — see
  /// `ProjectFeature.State.worktreeReclaimOffers`.
  var reclaimOffer: WorktreeAssessment?
  var onReclaim: (() -> Void)?
  var onKeep: (() -> Void)?

  enum Metrics {
    static let size = CGSize(width: 250, height: 106)
    static let radius: CGFloat = 11
    static let stripe: CGFloat = 4
    /// The entry port, half of it outside the card's leading edge.
    static let port: CGFloat = 10
  }

  /// The rollup decides, never the state on its own. A node blocked on an upstream that
  /// is still running is the graph working correctly — `AttentionRollup` deliberately
  /// leaves those out, and a card that warmed up for every `.blocked` node would put the
  /// canvas back to burying two real problems under fifteen normal ones. The card's
  /// *action* still follows the state: there is nothing to press about, only nothing to
  /// alarm about.
  private var needsAttention: Bool { reason != nil }

  var body: some View {
    let card = LoopCardPresentation(node: node, now: now, reclaimOffer: reclaimOffer)
    return VStack(alignment: .leading, spacing: 7) {
      titleRow
      if entryRole == .unwired {
        // Its own sentence, in prose rather than mono: this is the card talking about
        // the loop rather than quoting what the loop was handed.
        Text("Nothing runs it and it hands to nothing.")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.5))
          .lineLimit(1)
        unwiredActions
      } else {
        liveLine(card.liveLine)
        detail(card.detail)
      }
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
      .fill(node.loopType.accent.opacity(entryRole == .unwired ? 0.35 : 1))
      .frame(width: Metrics.stripe)
    }
    .clipShape(RoundedRectangle(cornerRadius: Metrics.radius))
    .overlay {
      RoundedRectangle(cornerRadius: Metrics.radius)
        .stroke(
          needsAttention ? Theme.loopCardAttentionBorder : Theme.loopCardBorder,
          style: StrokeStyle(lineWidth: 1, dash: entryRole == .unwired ? [4, 3] : []))
    }
    .cardGlow(needsAttention ? .orange : node.loopType.accent, emphasized: needsAttention)
    // The port hangs half outside the card, so it goes on last and outside the clip.
    .overlay(alignment: .leading) { entryPort }
    // Attention arriving is not a layout change: the ring and the glow cross-fade so a
    // graph someone is reading doesn't jump under them.
    .animation(.easeInOut(duration: 0.2), value: needsAttention)
  }

  /// A root's mark: a filled circle straddling the leading edge, ringed in the canvas
  /// tone so it reads as attached to the card rather than as something behind it.
  ///
  /// This is what replaced the start node. The fact "the graph begins here" belongs to
  /// the loop, so N roots cost N ports — where N tethers to one dot cost a starburst.
  @ViewBuilder
  private var entryPort: some View {
    if entryRole == .entry || entryRole == .unwired {
      // An unwired loop gets one too, dimmed. It is where the graph begins by default —
      // nothing hands off to it — and leaving it portless is what left three cards
      // floating in the middle of a canvas with a line-less origin beside them. The
      // dashed border and the desaturated stripe still say it was probably an accident.
      Circle()
        .fill(node.loopType.accent.opacity(entryRole == .unwired ? 0.4 : 1))
        .overlay(Circle().stroke(Theme.canvasTone, lineWidth: 2))
        .frame(width: Metrics.port, height: Metrics.port)
        .offset(x: -Metrics.port / 2)
        .allowsHitTesting(false)
    }
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(node.title)
        .font(.system(size: 14.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.95))
        .lineLimit(1)
      Spacer(minLength: 4)
      LoopStatePill(state: node.displayState, loopType: node.loopType)
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
    case .reclaim:
      // Quiet, not amber: the loop finished well, and nothing here is asking for
      // rescue — just whether a directory that already landed should keep its disk.
      HStack(spacing: 7) {
        Button("Reclaim") { onReclaim?() }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.82))
          .padding(.vertical, 3)
          .padding(.horizontal, 9)
          .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
          .overlay {
            RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.14), lineWidth: 1)
          }
        Button("Keep") { onKeep?() }
          .buttonStyle(.plain)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
  }

  /// The two verbs for a loop wired to nothing — one to give it an upstream, one to say
  /// it was meant to be a beginning all along. Both are cheaper than deleting it and
  /// starting again, which is what people did instead.
  private var unwiredActions: some View {
    HStack(spacing: 6) {
      Button("Wire it up") { onWireUp?() }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.vertical, 3)
        .padding(.horizontal, 9)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
      Button("Mark as entry") { onMarkAsEntry?() }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.5))
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
      if let follow = node.templateFollow {
        FollowsChip(follow: follow)
      }
      if isRemote {
        Image(systemName: "network").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
      }
      switch entryRole {
      case .entry: EntryChip()
      case .cycleOnly: CycleChip()
      case .interior, .unwired: EmptyView()
      }
    }
  }
}

/// A following loop's mark: a 5pt blue dot and the name of what it follows, with
/// "· missing" when the file could not be found at the last resolve. The blue is
/// the action blue the Templates button uses — the follow is chrome on the loop,
/// not a sixth kind of it.
struct FollowsChip: View {
  let follow: TemplateFollow

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(missing ? Color(red: 1.0, green: 0.624, blue: 0.039) : Theme.paneFocusTint)
        .frame(width: 5, height: 5)
      Text(follow.missing ? "Follows \(follow.name) · missing" : "Follows \(follow.name)")
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(missing ? Color(red: 1.0, green: 0.804, blue: 0.478) : .white.opacity(0.6))
        .lineLimit(1)
    }
    .padding(.vertical, 1)
    .padding(.horizontal, 6)
    .background(
      missing
        ? Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.12)
        : Theme.paneFocusTint.opacity(0.12),
      in: RoundedRectangle(cornerRadius: 4))
  }

  private var missing: Bool { follow.missing }
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
/// anything.
///
/// **It used to pulse while running, and that is deliberately gone.** The pulse was a
/// `repeatForever` opacity animation, which is the one kind that never settles: as long as
/// a single running dot is on screen the window has a live animation attached and keeps
/// recomposing at the display's refresh rate, forever. That is not one dot's worth of
/// cost. The same indicator draws on every running card and every sidebar row, so the app
/// could never reach an idle frame while any loop was running, and the cost landed next to
/// Ghostty's own rendering.
///
/// Nothing is lost by removing it. `LoopStateAppearance` already carries state on three
/// channels that survive greyscale, 40% zoom, and a protanope — hue, solid-or-hollow, and
/// a word — and motion was a fourth saying what the word already said.
struct StateIndicator: View {
  let state: LoopState
  var diameter: CGFloat = 6

  var body: some View {
    indicator
      .frame(width: diameter, height: diameter)
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
/// than a zero-width fill — see `LoopCardPresentation.Detail`. Shared with the
/// workspace's loop bar, which shows the same trend as the card.
struct ProgressTrack: View {
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
