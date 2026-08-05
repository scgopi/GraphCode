import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The orchestrator's monitoring surface as it appears in the sidebar
/// (docs/05-orchestrator.md#monitoring-surface): what needs a human.
///
/// The cost half of that surface is deliberately absent. It could only ever say "none
/// reporting": usage arrives from a backend writing `zmx set "$ZMX_SESSION" usage=…`
/// from a lifecycle hook, and graphcode does not install hooks into someone's Claude
/// Code settings on their behalf — so nothing ever wrote one. A panel that is
/// permanently empty teaches people to stop looking at the panel next to it, which is
/// the one that matters. `GraphStore` still collects usage and `graphcode usage <path>`
/// still prints it, so the day a hook exists there is something to show.
extension AppSidebarView {
  /// The orchestrator monitor's needs-attention rollup
  /// (docs/05-orchestrator.md#monitoring-surface), pinned above the projects.
  ///
  /// It lives here rather than in a panel of its own because "surface the one thing that
  /// needs me" only works if it's where you already are. It disappears entirely when
  /// nothing needs attention — an always-present empty queue trains people to stop
  /// looking at it.
  @ViewBuilder
  func attentionSection(collapsed: Binding<Bool>) -> some View {
    let items = store.attentionItems.oldestFirst
    if !items.isEmpty {
      HStack(spacing: 6) {
        Text("NEEDS YOU")
          .font(.system(size: 10.5, weight: .bold))
          .tracking(0.6)
          .foregroundStyle(Self.captionInk)
        Text("\(items.count)")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color(red: 0.106, green: 0.106, blue: 0.114))
          .padding(.vertical, 1)
          .padding(.horizontal, 6)
          .background(Self.badgeFill, in: Capsule())
        Spacer(minLength: 0)
        Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .frame(width: 12)
      }
      .contentShape(Rectangle())
      .onTapGesture { collapsed.wrappedValue.toggle() }
      if collapsed.wrappedValue {
        ForEach(items) { item in
          attentionRowCompact(for: item)
        }
      } else {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
          attentionRow(for: item, isOldest: index == 0)
        }
      }
      Divider()
    }
  }

  private func attentionRowCompact(for item: AttentionItem) -> some View {
    HStack(spacing: 7) {
      StateIndicator(state: state(for: item.reason), diameter: 7)
      Text(item.nodeTitle)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
      Spacer(minLength: 4)
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onTapGesture { store.send(.attentionItemTapped(item)) }
    .contextMenu {
      Button("Stop Loop", role: .destructive) {
        store.send(.stopNodeTapped(projectPath: item.projectPath, nodeID: item.nodeID))
      }
    }
  }

  private func attentionRow(for item: AttentionItem, isOldest: Bool) -> some View {
    HStack(spacing: 7) {
      StateIndicator(state: state(for: item.reason), diameter: 7)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.nodeTitle)
          .font(.system(size: 12.5))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
        Text("\(item.reason.displayName) · \(item.projectName)")
          .font(.system(size: 10.5))
          .foregroundStyle(Self.reasonInk)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      Text(LoopCardPresentation.duration(sidebarNow.timeIntervalSince(item.createdAt)))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.52))
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(
      isOldest ? Self.oldestFill : .clear, in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay {
      if isOldest {
        RoundedRectangle(cornerRadius: 6).stroke(Self.oldestBorder, lineWidth: 1)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { store.send(.attentionItemTapped(item)) }
    .contextMenu {
      Button("Stop Loop", role: .destructive) {
        store.send(.stopNodeTapped(projectPath: item.projectPath, nodeID: item.nodeID))
      }
    }
  }

  /// The state a reason came from, so the row's indicator is the same solid-or-hollow
  /// mark the card and the tab dot use rather than a third vocabulary.
  private func state(for reason: AttentionReason) -> LoopState {
    switch reason {
    case .failed: return .failed
    case .stalled: return .stalled
    case .awaitingInput: return .awaitingInput
    case .blocked: return .blocked
    }
  }

  private static let captionInk = Color(red: 1.0, green: 0.745, blue: 0.361)  // #ffbe5c
  private static let badgeFill = Color(red: 1.0, green: 0.624, blue: 0.039)
  private static let reasonInk = Color(red: 1.0, green: 0.745, blue: 0.361).opacity(0.75)
  private static let oldestFill = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.1)
  private static let oldestBorder = Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.22)

  private func icon(for reason: AttentionReason) -> String {
    switch reason {
    case .failed: return "xmark.octagon.fill"
    case .stalled: return "clock.badge.exclamationmark.fill"
    case .awaitingInput: return "bubble.left.fill"
    case .blocked: return "lock.fill"
    }
  }

  private func color(for reason: AttentionReason) -> Color {
    switch reason {
    case .failed: return .red
    case .stalled: return .purple
    case .awaitingInput: return .orange
    case .blocked: return .orange
    }
  }
}
