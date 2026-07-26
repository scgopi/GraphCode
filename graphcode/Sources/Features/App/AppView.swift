import ComposableArchitecture
import SwiftUI

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    if let detailStore = store.scope(state: \.detail, action: \.detail) {
      LoopNodeDetailView(store: detailStore)
    } else {
      creationForm
    }
  }

  private var creationForm: some View {
    VStack(spacing: 12) {
      Text("Graphcode").font(.largeTitle).bold()
      Text("Phase 1 scaffold — one loop node, turn-based, Claude Code only.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Form {
        TextField("Title", text: $store.draftTitle)
        TextField("Check", text: $store.draftCheck)
      }
      .frame(maxWidth: 360)
      Button("Create Loop Node") { store.send(.createNodeButtonTapped) }
        .keyboardShortcut(.defaultAction)
    }
    .padding(40)
    .frame(minWidth: 480, minHeight: 320)
  }
}

#Preview {
  AppView(store: Store(initialState: AppFeature.State()) { AppFeature() })
}
