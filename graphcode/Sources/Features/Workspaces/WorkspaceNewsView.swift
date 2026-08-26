import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Workspaces exist now — said once, to people who were already using GraphCode when they
/// landed. See `WorkspaceNews` for who that is.
///
/// A dialog rather than a tour page, because its audience has already done the tour. Three
/// lines, and the third one is the reason this dialog exists at all: the first question on
/// finding a "Default" label at the foot of a sidebar that never had one is whether your
/// loops are still there.
struct WorkspaceNewsView: View {
  @Bindable var store: StoreOf<AppFeature>
  let version: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        Text("NEW IN \(version)")
          .font(.system(size: 9, weight: .bold))
          .tracking(0.5)
          .foregroundStyle(Self.newInk)
          .padding(.vertical, 2)
          .padding(.horizontal, 6)
          .background(Self.newInk.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))

        Text("Workspaces")
          .font(.system(size: 19, weight: .bold))
          .tracking(-0.2)

        Text(
          "A second GraphCode with its own projects, loops and daemon — for keeping "
            + "unrelated work apart, or putting one window on each screen."
        )
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.65))
        .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 11) {
        item(
          "rectangle.split.2x1", "Make one from File ▸ Workspace",
          "It opens in its own window, with its own Dock tile.")
        item(
          "list.bullet", "Switch with ⌥⌘1 … ⌥⌘9, or ⌘` for the next one",
          "Or from the workspace name at the foot of the sidebar.")
        item(
          "arrow.up.to.line", "Nothing moved",
          "Everything you have is in the workspace called Default, exactly where it was.")
      }
      .padding(.top, 18)

      Text(
        "Also in this release: a new workspace opens cleanly the first time, updates are "
          + "handled from Default only, and updating offers to close your other workspace "
          + "windows first."
      )
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.45))
      .fixedSize(horizontal: false, vertical: true)
      .padding(11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.07), lineWidth: 1)
      }
      .padding(.top, 20)

      HStack {
        Text("Shown once")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.35))
        Spacer()
        Button("Release Notes") { store.send(.workspaces(.newsNotesTapped)) }
        Button("Got It") { store.send(.workspaces(.newsDismissed)) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(.top, 20)
    }
    .padding(26)
    .frame(width: 460)
  }

  private func item(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: symbol)
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.45))
        .frame(width: 15)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.92))
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.5))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private static let newInk = Color(red: 0.494, green: 0.894, blue: 0.608)
}
