import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The left pane of a project window (Phase 4, docs/07-roadmap.md#phase-4--projects):
/// every loop in the open folder's graph, listed as a navigable row, plus a pinned
/// "Graph" row for the pan/zoom canvas. Selecting a row is exactly today's
/// `.nodeTapped`/`.detailDismissed` actions — only the presentation changed, from a
/// modal sheet to swapping `ProjectView`'s detail pane.
struct ProjectSidebarView: View {
  @Bindable var store: StoreOf<ProjectFeature>

  private static let graphRowID = UUID()

  var body: some View {
    List(
      selection: Binding(
        get: { store.detail?.node.id ?? Self.graphRowID },
        set: { selection in
          if let selection, selection != Self.graphRowID {
            store.send(.nodeTapped(selection))
          } else {
            store.send(.detailDismissed)
          }
        }
      )
    ) {
      Section(store.graph.project.name) {
        Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
          .tag(Self.graphRowID)

        ForEach(store.graph.nodes) { node in
          nodeRow(for: node)
            .tag(node.id)
        }
      }
    }
    .listStyle(.sidebar)
    // The sidebar's own translucent material would ignore `Theme` and let the desktop
    // through, so hide it and fill with the flat gray instead.
    .scrollContentBackground(.hidden)
    .background(Theme.sidebarBackground)
    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.addNodeButtonTapped)
        } label: {
          Label("New Node", systemImage: "plus.circle")
        }
      }
    }
  }

  private func nodeRow(for node: LoopNode) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(node.title).lineLimit(1)
        Text(node.loopType.rawValue).font(.caption2).foregroundStyle(.secondary)
      }
    } icon: {
      Circle().fill(color(for: node.state)).frame(width: 8, height: 8)
    }
  }

  private func color(for state: LoopState) -> Color {
    switch state {
    case .idle: .gray
    case .running: .blue
    case .awaitingInput: .orange
    case .blocked: .orange
    case .succeeded: .green
    case .failed: .red
    case .stalled: .purple
    }
  }
}
