import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The detail-pane content `AppView` shows once no project is open yet — create a graph
/// for a folder or repository, or reopen one already known. Used to be the whole window
/// (Phase 4, docs/07-roadmap.md#phase-4--projects); the multi-project sidebar follow-up
/// made it detail-pane content instead, since the sidebar (always visible, listing
/// every open project) needs its own "add a folder" affordance regardless of whether
/// this view is currently showing — `AppSidebarView` owns the actual `.fileImporter`
/// presentation for the state this view's button sets, so folder-picking works from
/// either place without two competing importers.
///
/// Project chrome (the recents list included) lives only in the sidebar now —
/// `AppSidebarView`'s "Add Folder" menu already surfaces `store.recentProjects`, so this
/// view doesn't repeat it below the pitch text.
struct WelcomeView: View {
  @Bindable var store: StoreOf<WelcomeFeature>

  var body: some View {
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .frame(minWidth: 560, minHeight: 420)
  }
}

#Preview {
  WelcomeView(store: Store(initialState: WelcomeFeature.State()) { WelcomeFeature() })
}
