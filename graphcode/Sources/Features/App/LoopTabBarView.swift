import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// A tab per open loop terminal, mirroring the shape of supacode's own terminal tab
/// bar — but each tab here is a different *loop*, not a terminal session inside one
/// worktree, since a `LoopNode` is already exactly one CLI session (see
/// docs/07-roadmap.md's Projects phase follow-up). Switching tabs is instant and never
/// reconnects the underlying `zmx` session: `AppView` keeps every open tab's
/// `GhosttyTerminalNSView` mounted the whole time it's open, this bar just changes
/// which one is visible.
struct LoopTabBarView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(store.openTabs) { tab in
          tabPill(for: tab)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .background(Theme.sidebarBackground)
  }

  private func tabPill(for tab: LoopNodeDetailFeature.State) -> some View {
    let isActive = tab.id == store.activeTabID
    return HStack(spacing: 6) {
      Circle().fill(tab.node.state.presenceColor).frame(width: 6, height: 6)
      Text(tab.node.title).font(.caption).lineLimit(1)
      Button {
        store.send(.tabClosed(tab.id))
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isActive ? Theme.windowBackground : Color.clear)
    )
    .contentShape(Rectangle())
    .onTapGesture {
      store.send(.tabSelected(tab.id))
    }
  }
}
