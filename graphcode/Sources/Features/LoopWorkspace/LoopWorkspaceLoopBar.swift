import GraphcodeKit
import SwiftUI

/// The 46pt band above the tab strip: which loop this terminal belongs to, what it was
/// asked for, how far it has got, and how to stop it.
///
/// A header row was removed from this workspace once, and rightly — it repeated the
/// title the sidebar was already showing and the state dot beside it. This one is not
/// that. The goal, the pass count and the trend are on no other surface while a terminal
/// is up, and they are exactly what you lose track of after twenty minutes inside one:
/// the loop vanishes the moment you start working in it.
///
/// Deliberately not a title band. If everything here were removed except the name, it
/// should be deleted again.
struct LoopWorkspaceLoopBar: View {
  let node: LoopNode
  let now: Date
  let onStop: () -> Void
  let onShowInGraph: () -> Void

  private var card: LoopCardPresentation { LoopCardPresentation(node: node, now: now) }

  var body: some View {
    HStack(spacing: 12) {
      identity
      divider
      progress
      Spacer(minLength: 8)
      actions
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(Theme.loopBar)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1)
    }
  }

  private var identity: some View {
    HStack(spacing: 9) {
      RoundedRectangle(cornerRadius: 2)
        .fill(node.loopType.accent)
        .frame(width: 4, height: 24)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 7) {
          Text(node.title)
            .font(.system(size: 13.5, weight: .semibold))
            .lineLimit(1)
          LoopStatePill(state: node.state, loopType: node.loopType)
        }
        if let line = card.liveLine {
          Text(line)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .frame(maxWidth: 420, alignment: .leading)
        }
      }
    }
  }

  private var divider: some View {
    Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 26)
  }

  /// The same numbers the loop's card shows, from the same `LoopCardPresentation` — a
  /// bar that computed its own trend could disagree with the canvas about whether the
  /// work is going well, which is the one thing both surfaces exist to answer.
  @ViewBuilder
  private var progress: some View {
    HStack(spacing: 12) {
      if case .progress(let bar) = card.detail {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(passLabel).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 4)
            Text(bar.change).foregroundStyle(.white.opacity(0.5))
          }
          .font(.system(size: 10.5, design: .monospaced))
          ProgressTrack(fraction: bar.fraction, accent: node.loopType.accent)
        }
        .frame(width: 150)
      }
      Text(spend)
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.5))
    }
  }

  private var passLabel: String {
    node.metricHistory.isEmpty ? "no passes yet" : "pass \(node.metricHistory.count)"
  }

  private var spend: String {
    var parts = [LoopCardPresentation.duration(now.timeIntervalSince(node.createdAt))]
    // Only when the backend actually reported it — see `UsageSample`, which refuses to
    // estimate. A confident "0 tok" on a loop that has spent plenty is worse than silence.
    if let tokens = node.usage?.totalTokens {
      parts.append(LoopCardPresentation.tokens(tokens))
    }
    return parts.joined(separator: " · ")
  }

  private var actions: some View {
    HStack(spacing: 8) {
      // No Pause button. The design has one and the daemon has nothing behind it —
      // `graphcoded` can stop a loop, not suspend one — and a control that looks like it
      // holds a running agent while the agent keeps working is worse than no control.
      if !node.isResolved {
        barButton("Stop loop", action: onStop)
      }
      Button("Show in graph", action: onShowInGraph)
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.45))
    }
  }

  private func barButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .buttonStyle(.plain)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(.white.opacity(0.8))
      .padding(.vertical, 4)
      .padding(.horizontal, 10)
      .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.09), lineWidth: 1)
      }
  }
}
