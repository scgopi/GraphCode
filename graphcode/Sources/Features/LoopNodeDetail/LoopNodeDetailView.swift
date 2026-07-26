import ComposableArchitecture
import GraphcodeKit
import SwiftUI

struct LoopNodeDetailView: View {
  @Bindable var store: StoreOf<LoopNodeDetailFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      GhosttyTerminalView(node: store.node) { succeeded in
        store.send(.processExited(succeeded: succeeded))
      }
      if store.node.checkDescription != nil {
        Divider()
        checkBar
      }
    }
    .frame(minWidth: 640, minHeight: 420)
  }

  private var header: some View {
    HStack {
      Text(store.node.title).font(.headline)
      Spacer()
      PresenceBadge(state: store.node.state)
    }
    .padding(8)
  }

  private var checkBar: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("The check").font(.caption).foregroundStyle(.secondary)
        Text(store.node.checkDescription ?? "").font(.subheadline)
      }
      Spacer()
      Button("Reject") { store.send(.checkRejected) }
      Button("Approve") { store.send(.checkApproved) }
        .keyboardShortcut(.defaultAction)
    }
    .padding(8)
  }
}

private struct PresenceBadge: View {
  let state: LoopState

  var body: some View {
    Text(label)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.2))
      .foregroundStyle(color)
      .clipShape(Capsule())
  }

  private var label: String {
    switch state {
    case .idle: "Idle"
    case .running: "Running"
    case .awaitingInput: "Awaiting Input"
    case .blocked: "Blocked"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .stalled: "Stalled"
    }
  }

  private var color: Color {
    switch state {
    case .idle: .gray
    case .running: .blue
    case .awaitingInput: .orange
    case .blocked: .yellow
    case .succeeded: .green
    case .failed: .red
    case .stalled: .purple
    }
  }
}
