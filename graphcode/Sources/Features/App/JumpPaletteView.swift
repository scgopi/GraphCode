import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// ⌘K — type a loop's name, press Return, land in its workspace.
///
/// A list rather than the canvas or the sidebar, because neither of those is a way to
/// reach a loop *whose name you already know*: one is scrolled and one is panned, and
/// both cost you the thing you were doing. See `JumpPalette` for the ranking, which is
/// where the actual judgement is.
struct JumpPaletteView: View {
  @Bindable var store: StoreOf<AppFeature>

  @FocusState private var isFieldFocused: Bool

  private var results: [JumpPalette.Result] { store.jumpResults }

  var body: some View {
    VStack(spacing: 0) {
      field
      Divider()
      if results.isEmpty {
        Text("No loop matches “\(store.jumpQuery)”")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(14)
      } else {
        list
      }
    }
    .frame(width: 460)
    .frame(maxHeight: 380)
    .background(Theme.windowTone)
    .onAppear { isFieldFocused = true }
  }

  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      TextField("Jump to loop", text: $store.jumpQuery.sending(\.jumpQueryChanged))
        .textFieldStyle(.plain)
        .font(.system(size: 14))
        .focused($isFieldFocused)
        .onSubmit { openSelection() }
      Text("esc")
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
          row(result, isSelected: index == store.jumpSelection)
            .contentShape(Rectangle())
            .onTapGesture { store.send(.jumpItemSelected(result)) }
        }
      }
    }
    .scrollIndicators(.never)
    .background(selectionShortcuts)
  }

  private func row(_ result: JumpPalette.Result, isSelected: Bool) -> some View {
    HStack(spacing: 9) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(result.loopType.accent)
        .frame(width: 3, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(result.title).font(.system(size: 13)).lineLimit(1)
        Text(result.subtitle)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 6)
      StateIndicator(state: result.state, diameter: 6)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
  }

  /// ↑/↓ move the highlight; Return opens it. Hidden buttons for the same reason the
  /// workspace's shortcuts are — a `TextField` with focus eats arrow keys otherwise.
  private var selectionShortcuts: some View {
    Group {
      Button("") { store.send(.jumpSelectionMoved(1)) }
        .keyboardShortcut(.downArrow, modifiers: [])
      Button("") { store.send(.jumpSelectionMoved(-1)) }
        .keyboardShortcut(.upArrow, modifiers: [])
    }
    .frame(width: 0, height: 0)
    .opacity(0)
  }

  private func openSelection() {
    guard results.indices.contains(store.jumpSelection) else { return }
    store.send(.jumpItemSelected(results[store.jumpSelection]))
  }
}
