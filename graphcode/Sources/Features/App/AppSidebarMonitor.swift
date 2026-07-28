import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The orchestrator's monitoring surface as it appears in the sidebar
/// (docs/05-orchestrator.md#monitoring-surface): what needs a human, and what it has all
/// cost so far. Split out of `AppSidebarView` purely for size.
extension AppSidebarView {
  /// The orchestrator monitor's needs-attention rollup
  /// (docs/05-orchestrator.md#monitoring-surface), pinned above the projects.
  ///
  /// It lives here rather than in a panel of its own because "surface the one thing that
  /// needs me" only works if it's where you already are. It disappears entirely when
  /// nothing needs attention — an always-present empty queue trains people to stop
  /// looking at it.
  @ViewBuilder
  var attentionSection: some View {
    let items = store.attentionItems
    if !items.isEmpty {
      Text("Needs attention")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(items) { item in
        attentionRow(for: item)
      }
      Divider()
    }
  }

  /// The usage rollup from docs/05-orchestrator.md#monitoring-surface, in the same panel
  /// as needs-attention because "cost and attention are both things the orchestrator's
  /// monitoring surface exists to answer".
  ///
  /// It always states its coverage — "$0.12 · 2/9 loops reporting" — because graphcode
  /// cannot see inside a running `claude` and only knows what a backend's hooks tell it.
  /// A bare total would read as the whole bill when it might be a fraction of it, and a
  /// cost figure a human might act on has to be honest about what it left out.
  @ViewBuilder
  var usageSection: some View {
    let usage = store.usageRollup
    if usage.total > 0 {
      HStack(spacing: 6) {
        Image(systemName: "chart.bar").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
          Text(usage.headline).font(.callout)
          Text(usage.coverage).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.send(.refreshUsageTapped)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Ask each loop's backend what it has spent")
      }
      Divider()
    }
  }

  private func attentionRow(for item: AttentionItem) -> some View {
    HStack(spacing: 6) {
      Image(systemName: icon(for: item.reason))
        .foregroundStyle(color(for: item.reason))
      VStack(alignment: .leading, spacing: 1) {
        Text(item.nodeTitle).font(.callout).lineLimit(1)
        // The project name matters here in a way it doesn't in the per-project rows
        // below: this list is the one place loops from different projects sit together.
        Text("\(item.reason.displayName) · \(item.projectName)")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    .onTapGesture { store.send(.attentionItemTapped(item)) }
    .contextMenu {
      Button("Stop Loop", role: .destructive) {
        store.send(.stopNodeTapped(projectPath: item.projectPath, nodeID: item.nodeID))
      }
    }
  }

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
