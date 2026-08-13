import GraphcodeKit
import SwiftUI

/// The summary rail — what this loop is doing, in beats, at the top of the workspace rail.
///
/// The terminal beside it is the record; this is the answer. A pass 1,284 lines into a
/// grep is eleven words here, and the point of the feature is that nobody has to read the
/// first to know the second.
///
/// One shape, four depths: the current beat at full size, the two before it collapsed and
/// dimming with age, a pass line where the metric moved, and one row per finished pass
/// down to a count. A six-hour loop and a six-minute one are the same height — see
/// `LoopSummary`, which is bounded by construction.
struct LoopSummarySection: View {
  let node: LoopNode
  let now: Date
  let isFolded: Bool
  /// The newest beat this window had on screen when the human last left it — what the
  /// `SINCE YOU LOOKED` hairline is drawn against.
  let seenBeatID: String?
  let onToggleFold: () -> Void
  /// Brings the keyboard to the agent's own pane. The rail already owns "what is it
  /// doing", so a question is just the current beat wearing amber — and answering it is
  /// typing into the terminal that asked.
  let onAnswer: () -> Void

  private var presentation: LoopSummaryPresentation {
    LoopSummaryPresentation(node: node, now: now, seenBeatID: seenBeatID)
  }

  /// Whether the flowing spine should move. Only while the loop is actually working —
  /// see `FlowingSpine` for why that guard is load-bearing rather than cosmetic.
  private var isWorking: Bool {
    node.presence?.presence == .busy && !node.isResolved
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      let presentation = presentation
      header(presentation)
      if isFolded {
        foldedLine(presentation)
      } else {
        // History above, now at the foot — the same direction as the terminal beside it,
        // and the direction the spine's segment travels. Scrolled to the bottom, so the
        // current beat is what you land on and older work is a scroll up, exactly as
        // scrollback is.
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 10) {
            if !presentation.receding.isEmpty || !presentation.passes.isEmpty
              || presentation.earlierPasses > 0
            {
              history(presentation)
            }
            nowBlock(presentation)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        // Flexible, but never squeezed away: the sections under it are fixed-height, so
        // without a floor a short window would collapse the one section the rail is now
        // mostly for.
        .frame(minHeight: 120, maxHeight: .infinity)
      }
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }
  }

  // MARK: - Header

  /// `DOING NOW`, how long the current beat has been current, and the disclosure. The
  /// whole row is the fold target — a 14pt chevron is not a click target anyone aims at.
  private func header(_ presentation: LoopSummaryPresentation) -> some View {
    HStack(spacing: 7) {
      Text(headerTitle(presentation))
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.63)
        .foregroundStyle(.white.opacity(0.5))
      Spacer(minLength: 0)
      if let elapsed = presentation.elapsed, !isFolded {
        Text(elapsed)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.55))
      }
      Image(systemName: isFolded ? "chevron.down" : "chevron.up")
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 14, height: 14)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 3))
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onToggleFold)
    .help(isFolded ? "Show what this loop is doing" : "Collapse to one line")
  }

  /// `DOING NOW` is a claim, and it is only true while something is producing beats. A
  /// session that has finished its turn and is sitting at its prompt gets `LAST DID` — the
  /// same sentence, in the tense it is actually in.
  private func headerTitle(_ presentation: LoopSummaryPresentation) -> String {
    switch presentation.mode {
    case .resolved: return "WHAT IT DID"
    case .asking: return "ASKING YOU"
    case .starting: return "DOING NOW"
    case .working: return presentation.isLive ? "DOING NOW" : "LAST DID"
    }
  }

  /// Folded keeps one truncated line, because a folded section that shows nothing is a
  /// section you forget exists.
  private func foldedLine(_ presentation: LoopSummaryPresentation) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(BeatKindAppearance.dot(presentation.kind))
        .frame(width: 6, height: 6)
      Text(presentation.text)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
  }

  // MARK: - Now

  private func nowBlock(_ presentation: LoopSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: presentation.mode == .asking ? 7 : 6) {
      HStack(spacing: 5) {
        Circle()
          .fill(BeatKindAppearance.dot(presentation.kind))
          .frame(width: 6, height: 6)
        Text(kindWord(presentation).uppercased())
          .font(.system(size: 9.5, weight: .bold))
          .tracking(0.48)
          .foregroundStyle(BeatKindAppearance.ink(presentation.kind))
        Spacer(minLength: 0)
      }
      Text(presentation.text)
        .font(.system(size: 13))
        .lineSpacing(2.2)
        .foregroundStyle(.white.opacity(presentation.mode == .starting ? 0.7 : 0.94))
        .fixedSize(horizontal: false, vertical: true)
      if let evidence = presentation.evidence {
        Text(evidence)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.white.opacity(presentation.mode == .starting ? 0.45 : 0.55))
          .lineLimit(2)
      }
      if presentation.mode == .asking {
        Button(action: onAnswer) {
          Text("Answer it")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color(red: 0.141, green: 0.090, blue: 0.012))
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(
              BeatKindAppearance.dot(.asking).opacity(0.9),
              in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      BeatKindAppearance.blockFill(presentation.mode, kind: presentation.kind),
      in: RoundedRectangle(cornerRadius: 9)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 9)
        .stroke(
          BeatKindAppearance.blockBorder(presentation.mode, kind: presentation.kind),
          lineWidth: 1)
    }
  }

  private func kindWord(_ presentation: LoopSummaryPresentation) -> String {
    presentation.mode == .asking ? "asking you" : presentation.kind.rawValue
  }

  // MARK: - History

  /// Everything behind the current beat, oldest at the top, on one spine: the finished
  /// passes, the line where this pass began, then this pass's beats in the order they
  /// happened.
  private func history(_ presentation: LoopSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !presentation.passes.isEmpty || presentation.earlierPasses > 0 {
        rollups(presentation)
      }
      if let label = presentation.passLabel {
        passDivider(label, delta: presentation.passDelta)
      }
      let beats = presentation.receding
      // The hairline sits before the first beat the human has not seen, which is
      // `unseen` rows from the end.
      let firstUnseen = beats.count - presentation.unseen
      ForEach(Array(beats.enumerated()), id: \.element.id) { index, beat in
        if index == firstUnseen, presentation.unseen > 0 {
          sinceYouLooked
        }
        recedingRow(beat, age: age(of: index, in: beats.count))
      }
    }
    .padding(.leading, 16)
    .background(alignment: .leading) {
      FlowingSpine(isFlowing: isFlowing)
        .frame(width: 1)
        .padding(.leading, 4)
        .padding(.vertical, 3)
    }
  }

  /// The spine only animates when there is something behind the current beat to have
  /// flowed from, and only while the session is live.
  private var isFlowing: Bool {
    isWorking && !presentation.receding.isEmpty
  }

  /// How faded a row is by its position: 0 at the top of the list, 1 for the one just
  /// above the current beat. A single recent/older split was enough for two rows and is
  /// not for twelve.
  private func age(of index: Int, in count: Int) -> Double {
    guard count > 1 else { return 1 }
    return Double(index) / Double(count - 1)
  }

  /// A beat that is no longer current: one line, a dot on the spine, dimming with age.
  ///
  /// The dimming is the one place in the rail exempt from the project's tertiary-ink floor
  /// — `.72` down to `.42` on beat body text is deliberate signal about recency, not a
  /// contrast accident, and the design says so explicitly.
  private func recedingRow(_ beat: SummaryBeat, age: Double) -> some View {
    let isRecent = age > 0.999
    return VStack(alignment: .leading, spacing: 3) {
      Text(beat.text)
        .font(.system(size: 11.5))
        .lineSpacing(1.6)
        .foregroundStyle(.white.opacity(0.42 + 0.30 * age))
        .fixedSize(horizontal: false, vertical: true)
      if isRecent {
        Text(LoopCardPresentation.duration(now.timeIntervalSince(beat.at)) + " ago")
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .topLeading) {
      // The dot keeps its kind colour at every depth, dimmed rather than greyed. The
      // claim the six kinds exist to make — that the shape of a pass is legible from the
      // dots alone, without reading a word — is only true if the older dots still carry
      // one, and over twelve rows that is where the shape actually shows.
      Circle()
        .fill(BeatKindAppearance.dot(beat.kind).opacity(0.45 + 0.55 * age))
        .frame(width: isRecent ? 7 : 5, height: isRecent ? 7 : 5)
        .overlay { Circle().stroke(Theme.workspaceRail, lineWidth: 2) }
        .offset(x: isRecent ? -15 : -14, y: 4)
    }
  }

  /// Where the human left off. It moves only when the loop is on screen again — see
  /// `LoopWorkspaceFeature.summarySeen` — never while they are reading.
  private var sinceYouLooked: some View {
    HStack(spacing: 7) {
      Text("SINCE YOU LOOKED")
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.38)
        .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.85))
      Rectangle().fill(Theme.paneFocusTint.opacity(0.35)).frame(height: 1)
    }
    .padding(.bottom, 8)
  }

  /// The only number in the section.
  private func passDivider(_ label: String, delta: String?) -> some View {
    HStack(spacing: 7) {
      Text(label)
        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
      Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
      if let delta {
        Text(delta)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(Color(red: 0.310, green: 0.769, blue: 0.561))  // #4fc48f
          .lineLimit(1)
      }
    }
    .padding(.vertical, 5)
  }

  /// One row per finished pass, then a count. Six hours of work stays six rows tall.
  private func rollups(_ presentation: LoopSummaryPresentation) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(presentation.passes) { pass in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("p\(pass.pass)")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
            .frame(width: 26, alignment: .leading)
          Text(pass.text)
            .font(.system(size: 11))
            .lineSpacing(1.4)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if presentation.earlierPasses > 0 {
        Text(
          "\(presentation.earlierPasses) earlier "
            + (presentation.earlierPasses == 1 ? "pass" : "passes")
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.white.opacity(0.5))
        .padding(.leading, 32)
      }
    }
  }
}

/// The 1pt spine behind the receding beats, with a gradient segment travelling *up* it.
///
/// **Why an animation exists here at all.** `StateIndicator` documents why the running
/// dot's pulse was removed: a `repeatForever` animation never settles, and that one was
/// attached to every card and every sidebar row, so the app could not reach an idle frame
/// while any loop ran. This is the opposite case on every count that mattered there. There
/// is exactly **one** of these in a window — the workspace shows one loop — it is drawn
/// only when the rail is open and unfolded, and `isFlowing` stops it the moment the
/// session is not busy or there is nothing behind the current beat. A canvas of forty
/// cards animates nothing.
///
/// It earns its place by saying the one thing no static rail can: that beats are still
/// arriving. A spinner says "something is happening"; this says "the thing you are reading
/// is moving", which is what a rail of receding text is for.
private struct FlowingSpine: View {
  let isFlowing: Bool

  @State private var phase: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      let height = proxy.size.height
      Rectangle()
        .fill(.white.opacity(0.1))
        .overlay(alignment: .top) {
          if isFlowing {
            RoundedRectangle(cornerRadius: 1)
              .fill(
                LinearGradient(
                  colors: [
                    Theme.paneFocusTint.opacity(0), Theme.paneFocusTint,
                    Theme.paneFocusTint.opacity(0),
                  ],
                  startPoint: .top, endPoint: .bottom)
              )
              .frame(width: 2, height: 26)
              .offset(x: -0.5, y: (height + 26) * (1 - phase) - 26)
              .onAppear {
                phase = 0
                withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                  phase = 1
                }
              }
          }
        }
        .clipped()
    }
  }
}
