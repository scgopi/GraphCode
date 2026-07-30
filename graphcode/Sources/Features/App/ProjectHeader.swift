import SwiftUI

/// Which folder a loop's terminal belongs to, at the top of its workspace.
///
/// Only the workspace needs it: the canvas is reached by picking a project in the
/// sidebar and leaves that row selected in view, but once a terminal fills the pane —
/// with the sidebar collapsible and several repos open at once — nothing on screen says
/// which repo these shells are running in.
///
/// A filled blue folder rather than the sidebar's outline glyph: at a single instance
/// per screen it's a landmark, not a list item, and the color is what makes it findable
/// at a glance against a wall of terminal text.
struct ProjectHeader: View {
  let name: String
  /// A remote repository wears the `network` glyph instead of the folder, matching its
  /// sidebar row — the shells under this header run on another machine, and that is
  /// worth a glance-level signal in exactly the place people check which repo they're in.
  var isRemote = false

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: isRemote ? "network" : "folder.fill")
        .font(.system(size: 12))
        .foregroundStyle(Theme.folderGlyph)
      Text(name)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Project \(name)")
  }
}

#Preview {
  ProjectHeader(name: "qwen3.5")
    .padding()
    .background(Theme.windowBackground)
}
