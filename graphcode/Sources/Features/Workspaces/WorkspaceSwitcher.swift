import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The list of workspaces, as menu items — the same contents whether it is reached from
/// the sidebar's foot or from the File menu.
///
/// Picking one raises the instance that has it open, or launches one. Picking the current
/// workspace does nothing, so the row stays selectable-looking rather than dimmed: a
/// checkmark says which one you are in.
struct WorkspaceMenuItems: View {
  @Bindable var store: StoreOf<AppFeature>
  /// Only the menu bar's copy carries them. The same items also render in the sidebar's
  /// popup, and a key equivalent declared twice is one macOS resolves by picking a
  /// winner — which is not a thing to leave to chance for a command that moves windows.
  var showsShortcuts = false

  var body: some View {
    ForEach(Array(store.workspaces.known.enumerated()), id: \.element.id) { index, workspace in
      Button {
        store.send(.workspaces(.switchRequested(workspace)))
      } label: {
        if workspace.id == store.workspaces.current.id {
          Label(workspace.name, systemImage: "checkmark")
        } else {
          Text(workspace.name)
        }
      }
      // ⌥⌘1…9, in list order — ⌘1…9 belong to the terminal's tabs and ⌘⇧3/4/5 to the
      // system's screenshots, which leaves this the free row of number keys. Past the
      // ninth the rows stay clickable and simply carry no shortcut.
      .modifier(WorkspaceShortcut(index: showsShortcuts ? index : nil))
    }
    Divider()
    Button("New Workspace…") { store.send(.workspaces(.newRequested)) }
      .modifier(NewWorkspaceShortcut(isEnabled: showsShortcuts))
    if !deletable.isEmpty {
      Menu("Delete Workspace") {
        ForEach(deletable) { workspace in
          Button("\(workspace.name)…") { store.send(.workspaces(.deleteRequested(workspace))) }
        }
      }
    }
  }

  /// Never the default, and never the one this window is using — the two `Workspace`
  /// refuses anyway. Offering them and then explaining why not is worse than not offering.
  private var deletable: [Workspace] {
    store.workspaces.known.filter { !$0.isDefault && $0.id != store.workspaces.current.id }
  }
}

/// The ⌥⌘<n> on a workspace row, for the first nine only.
///
/// A modifier rather than an inline `if`: `keyboardShortcut` has no conditional form, and
/// branching in the `ForEach` body would give the two branches different view identities.
private struct WorkspaceShortcut: ViewModifier {
  /// `nil` for the sidebar's copy of the menu, which carries no shortcuts.
  let index: Int?

  func body(content: Content) -> some View {
    if let index, index < 9, let key = KeyEquivalent(exactly: index + 1) {
      content.keyboardShortcut(key, modifiers: [.command, .option])
    } else {
      content
    }
  }
}

/// ⌥⌘N — ⌘N is New Window, which SwiftUI gives every `WindowGroup` for free.
private struct NewWorkspaceShortcut: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if isEnabled {
      content.keyboardShortcut("n", modifiers: [.command, .option])
    } else {
      content
    }
  }
}

extension KeyEquivalent {
  /// `KeyEquivalent("1")` from a digit, for building a run of number shortcuts.
  fileprivate init?(exactly digit: Int) {
    guard let scalar = String(digit).unicodeScalars.first, String(digit).count == 1 else {
      return nil
    }
    self.init(Character(scalar))
  }
}

/// The sidebar's foot: which workspace this window is, and the way to another.
///
/// Present only once there is something to disambiguate (`isWorthShowing`) — and needed
/// then, because two workspaces are two instances of the same app with the same icon and
/// the same hidden titlebar, and nothing else on screen says which is which.
struct WorkspaceFooter: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    if store.workspaces.isWorthShowing {
      Menu {
        WorkspaceMenuItems(store: store)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "square.stack.3d.up")
            .imageScale(.small)
          Text(store.workspaces.current.name)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .contentShape(.rect)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }
}
