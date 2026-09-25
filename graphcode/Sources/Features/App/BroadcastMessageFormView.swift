import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Send Message to All Loops… — one message for every loop's session, in
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

  private var loopCount: Int {
    store.projects.reduce(0) { $0 + $1.graph.broadcastLoopCount }
  }

  private var canSend: Bool {
    loopCount > 0
      && !(store.sessionRestart.broadcastDraft ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var summary: String {
    let loops = loopCount == 1 ? "1 loop" : "\(loopCount) loops"
    return "Sent to all \(loops) across your open projects, as if with graphcode node send: "
      + "typed into each session that can take it, and saved to the others' memory for "
      + "their next wake. ⌘↩ sends."
  }
}
