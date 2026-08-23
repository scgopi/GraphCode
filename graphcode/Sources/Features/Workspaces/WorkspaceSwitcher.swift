import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The list of workspaces as menu items — what `File ▸ Workspace` shows.
///
/// Picking one raises the instance that has it open, or launches one. Picking the current
/// workspace does nothing, so the row stays selectable-looking rather than dimmed: a
/// checkmark says which one you are in.
///
/// Rename and Delete are *not* here. They were two submenus of this submenu, which put
/// deleting a workspace four levels down a menu; they live in Manage Workspaces… now,
/// where both verbs are one click from the workspace they act on.
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
    Button("Manage Workspaces…") { store.send(.workspaces(.manageRequested)) }
      .disabled(store.workspaces.known.count < 2)
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
      VStack(spacing: 0) {
        // The rule above it, full width: without one the row reads as one more project
        // at the end of the list rather than as the thing the whole list belongs to.
        Divider().overlay(.white.opacity(0.09))

        row
      }
      // Opaque, and this is the whole bug it fixes: a `safeAreaInset` reserves space but
      // paints nothing, so with more loops than fit, rows scrolled *under* the footer and
      // straight through it — the workspace name and its icon sitting on top of moving
      // text, both illegible. The bar material rather than a flat colour, so it belongs
      // to the same glass the sidebar is made of.
      .background(.bar)
    }
  }

  private var row: some View {
    Group {
      Button {
        store.send(.workspaces(.switcherPresented(true)))
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "square.stack.3d.up")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
          // A project row's size, not two steps under it. This names the window you are
          // in — on a second screen it is the only thing that does — and at `.caption`
          // it was the smallest text in the sidebar.
          Text(store.workspaces.current.name)
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 4)
          // Says it opens something. The row is a switcher, and a bare label invites
          // nobody to click it.
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .popover(
        isPresented: Binding(
          get: { store.workspaces.isSwitcherPresented },
          set: { store.send(.workspaces(.switcherPresented($0))) }),
        arrowEdge: .top
      ) {
        WorkspaceSwitcherPanel(store: store)
      }
    }
  }
}

/// The switcher itself — a panel rather than a menu, because a menu row cannot say what
/// is *in* a workspace.
///
/// Which is the whole point of it: switching workspaces from a bare list of names is a
/// guess, and the two facts that make it a decision — how much is in there, and whether a
/// window already has it — are both cheap to read from outside (`Workspace.summary`).
struct WorkspaceSwitcherPanel: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(Array(store.workspaces.known.enumerated()), id: \.element.id) { index, workspace in
        row(workspace, index: index)
      }

      Divider().padding(.vertical, 5).padding(.horizontal, 8)

      action("New Workspace…", systemImage: "plus") {
        store.send(.workspaces(.switcherPresented(false)))
        store.send(.workspaces(.newRequested))
      }
      action("Manage Workspaces…", systemImage: "pencil") {
        store.send(.workspaces(.switcherPresented(false)))
        store.send(.workspaces(.manageRequested))
      }
      .disabled(store.workspaces.known.count < 2)
    }
    .padding(6)
    .frame(width: 300)
  }

  private func row(_ workspace: Workspace, index: Int) -> some View {
    let isCurrent = workspace.id == store.workspaces.current.id
    let summary = store.workspaces.summaries[workspace.id]
    return Button {
      store.send(.workspaces(.switcherPresented(false)))
      store.send(.workspaces(.switchRequested(workspace)))
    } label: {
      HStack(spacing: 9) {
        Circle()
          .fill(WorkspaceSwitcherPanel.tint(for: workspace))
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 1) {
          Text(workspace.name).font(.system(size: 13))
          Text(WorkspaceSwitcherPanel.subtitle(summary, isCurrent: isCurrent))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.42))
        }
        Spacer(minLength: 8)
        if index < 9 {
          Text("⌥⌘\(index + 1)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .background(
        isCurrent ? Color.white.opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  private func action(
    _ title: String, systemImage: String, perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .font(.system(size: 11))
          .frame(width: 7)
        Text(title).font(.system(size: 13))
        Spacer(minLength: 0)
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  /// A stable colour per workspace, so the dot is worth glancing at: the same workspace
  /// keeps the same one across launches and across windows. Hashed from the slug rather
  /// than assigned by position — a list that reorders must not repaint every dot.
  static func tint(for workspace: Workspace) -> Color {
    guard !workspace.isDefault else { return Theme.paneFocusTint }
    let palette: [Color] = [
      Color(red: 0.847, green: 0.651, blue: 0.341),
      Color(red: 0.616, green: 0.545, blue: 0.847),
      Color(red: 0.435, green: 0.827, blue: 0.671),
      Color(red: 0.898, green: 0.541, blue: 0.494),
      Color(red: 0.435, green: 0.702, blue: 0.898),
    ]
    let hash = workspace.slug.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return palette[hash % palette.count]
  }

  /// What the row says under the name. "not running" is the one worth naming outright:
  /// switching to it means launching an instance, which takes a moment and a Dock tile.
  static func subtitle(_ summary: Workspace.Summary?, isCurrent: Bool) -> String {
    guard let summary else { return isCurrent ? "this window" : "—" }
    let loops = "\(summary.loops) loop\(summary.loops == 1 ? "" : "s")"
    if isCurrent { return "\(loops) · this window" }
    return summary.isOpen ? "\(loops) · open" : "\(loops) · not running"
  }
}
