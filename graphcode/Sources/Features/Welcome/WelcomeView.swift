import ComposableArchitecture
import GraphcodeKit
import SwiftUI
import UniformTypeIdentifiers

/// Phase 4's welcome screen (docs/07-roadmap.md#phase-4--projects) — create a graph for
/// a folder or repository, or reopen one already known.
struct WelcomeView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      VStack(spacing: 12) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)
        Text("Create a graph of loops for a folder").font(.title2)
        Text(
          "Open a folder or git repository to start orchestrating a graph of AI coding loops in it."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 380)
        Button("Open Folder…") {
          store.send(.openFolderButtonTapped)
        }
        .keyboardShortcut("o", modifiers: .command)
        if let errorMessage = store.errorMessage {
          Text(errorMessage).font(.caption).foregroundStyle(.red)
        }
      }
      Spacer()
      if !store.recentProjects.isEmpty {
        Divider()
        recentProjectsList
      }
    }
    .frame(minWidth: 560, minHeight: 420)
    .fileImporter(
      isPresented: Binding(
        get: { store.isOpenPanelPresented },
        set: { store.send(.setOpenPanelPresented($0)) }
      ),
      allowedContentTypes: [.folder]
    ) { result in
      store.send(.folderPickerResult(result))
    }
  }

  private var recentProjectsList: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Recent").font(.caption).foregroundStyle(.secondary).padding(12)
      ForEach(store.recentProjects) { project in
        Button {
          store.send(.recentProjectTapped(project))
        } label: {
          HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading) {
              Text(project.name)
              Text(project.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
          }
          .contentShape(Rectangle())
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: 200)
  }
}

#Preview {
  WelcomeView(store: Store(initialState: WelcomeFeature.State()) { WelcomeFeature() })
}
