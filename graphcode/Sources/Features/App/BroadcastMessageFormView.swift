import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Send Message to All Loops… — one message typed into every live loop's session, in
/// every open project, the way `graphcode node send` types into one. A sheet rather than
/// an alert with a field for the reason every text entry here is one: it has to take the
/// keyboard over a terminal that holds first responder.
struct BroadcastMessageFormView: View {
  @Bindable var store: StoreOf<AppFeature>
  @FocusState private var isEditing: Bool

  var body: some View {
    VStack(spacing: 12) {
      Text("Send Message to All Loops").font(.headline)

      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      TextEditor(text: draft)
        .font(.body)
        .frame(height: 120)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .focused($isEditing)

      HStack {
        Button("Cancel") { store.send(.sessionRestart(.broadcastCancelled)) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Send") { store.send(.sessionRestart(.broadcastConfirmed)) }
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(!canSend)
      }
    }
    .padding(24)
    .frame(width: 420)
    .onAppear { isEditing = true }
  }

  private var draft: Binding<String> {
    Binding(
      get: { store.sessionRestart.broadcastDraft ?? "" },
      set: { store.send(.sessionRestart(.broadcastDraftChanged($0))) })
  }

  private var liveLoops: Int {
    store.projects.reduce(0) { $0 + $1.graph.liveLoopCount }
  }

  private var canSend: Bool {
    liveLoops > 0
      && !(store.sessionRestart.broadcastDraft ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var summary: String {
    let loops = liveLoops == 1 ? "1 live loop" : "\(liveLoops) live loops"
    return "Typed into the sessions of \(loops) across your open projects, as if sent with "
      + "graphcode node send. Loops that aren't running right now don't get it. ⌘↩ sends."
  }
}
