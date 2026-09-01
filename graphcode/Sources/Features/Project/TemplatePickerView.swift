import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The ⌘T picker — search-first, replacing the dialog's body while it is open, never
/// a second window (PROMPT_TEMPLATES.md § Picker).
///
/// Grouped by scope with the project's committed templates above the home library;
/// each row shows the shape as a swatch in that type's hue, the brief's first
/// sentence, and a metadata line: token chips, what the template sets, and how
/// many times it has been used. Keys: ↑↓ move, ⏎ fill, ⌘⏎ start now, ⎋ back.
struct TemplatePickerView: View {
  let store: StoreOf<ProjectFeature>
  @FocusState private var searchFocused: Bool

  private var rows: [ProjectFeature.TemplatePickerRow] {
    store.templatePickerRows
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      searchField
      if rows.isEmpty {
        emptyState
      } else {
        list
      }
      Divider().overlay(Color.white.opacity(0.07))
      footer
    }
    .onAppear {
      // Search-first: the field owns the keyboard from the moment the picker
      // opens, which is what makes ↑↓ and ⏎ usable before the mouse is.
      searchFocused = true
    }
  }

  private var searchField: some View {
    HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.45))
      TextField(
        "Search templates",
        text: Binding(
          get: { store.templates.query },
          set: { store.send(.templateQueryChanged($0)) }
        )
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .focused($searchFocused)
      // The keys live on the search field: it owns focus from the moment the picker
      // opens, so ↑↓ ⏎ ⌘⏎ ⎋ all answer before the mouse is needed.
      .onKeyPress { event in
        switch event.key {
        case .upArrow:
          store.send(.templateSelectionMoved(-1))
          return .handled
        case .downArrow:
          store.send(.templateSelectionMoved(1))
          return .handled
        case .return:
          pressCurrent(event.modifiers.contains(.command) ? .launch : .fill)
          return .handled
        case .escape:
          store.send(.templatePickerClosed)
          return .handled
        default:
          return .ignored
        }
      }
      if !store.templates.query.isEmpty {
        Button {
          store.send(.templateQueryChanged(""))
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 11)
    .frame(height: 34)
    .background(Theme.draftField, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Theme.paneFocusTint, lineWidth: 1.5)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Theme.paneFocusTint.opacity(0.16), lineWidth: 3)
        .padding(-1.5)
    }
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(grouped, id: \.scope) { group in
            Text(group.scope.displayName.uppercased())
              .font(.system(size: 10.5, weight: .bold))
              .tracking(0.5)
              .foregroundStyle(.white.opacity(0.4))
              .padding(
                .top,
                group.scope == .home && !grouped[0].scope.isProjectEquivalent
                  ? 10 : 2
              )
              .padding(.bottom, 3)
              .padding(.leading, 2)
            ForEach(group.items) { row in
              rowView(row, isSelected: flatIndex(row) == store.templates.selectionIndex)
                .id(row.id)
            }
          }
        }
        .padding(.vertical, 2)
      }
      .onChange(of: store.templates.selectionIndex) { _, index in
        guard let index, index < rows.count else { return }
        withAnimation(.easeOut(duration: 0.12)) {
          proxy.scrollTo(rows[index].id, anchor: .center)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        store.templates.query.isEmpty
          ? "No templates yet — save one from a loop that worked."
          : "No template matches “\(store.templates.query)”."
      )
      .font(.system(size: 12.5))
      .foregroundStyle(.white.opacity(0.55))
      .padding(.vertical, 14)
      .padding(.horizontal, 2)
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text("↑↓ to move · ⏎ to fill in · ⌘⏎ to start now")
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.5))
      Spacer(minLength: 8)
      SettingsLink {
        Text("Manage…")
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0))
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Rows

  private struct Group {
    let scope: ProjectFeature.TemplatePickerScope
    var items: [ProjectFeature.TemplatePickerRow]
  }

  private var grouped: [Group] {
    var groups: [Group] = []
    for row in rows {
      if let last = groups.last, last.scope.displayName == row.scope.displayName {
        groups[groups.count - 1].items.append(row)
      } else {
        groups.append(Group(scope: row.scope, items: [row]))
      }
    }
    return groups
  }

  private func flatIndex(_ row: ProjectFeature.TemplatePickerRow) -> Int? {
    rows.firstIndex(where: { $0.id == row.id })
  }

  private func rowView(_ row: ProjectFeature.TemplatePickerRow, isSelected: Bool) -> some View {
    Button {
      // The row that was clicked, not the row the keyboard is on. `pressCurrent` is
      // for the keys, which have no other way of saying which row they mean.
      store.send(.templateChosen(row.template.id))
    } label: {
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 2)
          .fill(
            (row.template.shape ?? .sketch).accent.opacity(
              row.template.shape == nil ? 0.8 : 1)
          )
          .frame(width: 9, height: 9)
          .padding(.top, 4)
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(row.template.name)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.88))
              .lineLimit(1)
            Text(row.typeLabel)
              .font(.system(size: 10.5))
              .foregroundStyle(.white.opacity(0.45))
          }
          Text(row.template.summaryLine)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .truncationMode(.tail)
          metaChips(row)
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 9)
      .padding(.horizontal, 11)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isSelected ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 9)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9)
          .stroke(
            isSelected ? Theme.paneFocusTint.opacity(0.42) : .white.opacity(0.07), lineWidth: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private func metaChips(_ row: ProjectFeature.TemplatePickerRow) -> some View {
    let chips =
      tokenChips(row.template) + settingChips(row.template)
      + [useChip(row.template)].compactMap { $0 }
    if !chips.isEmpty {
      HStack(spacing: 5) {
        ForEach(chips, id: \.self) { chip in
          Text(chip.text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(
              chip.isToken ? Color(red: 0.549, green: 0.773, blue: 0.95) : .white.opacity(0.5)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
              chip.isToken
                ? Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.14)
                : Color.white.opacity(0.06),
              in: RoundedRectangle(cornerRadius: 4))
        }
      }
      .padding(.top, 2)
    }
  }

  private struct Chip: Hashable {
    let text: String
    let isToken: Bool
  }

  private func tokenChips(_ template: PromptTemplate) -> [Chip] {
    template.tokens.map { Chip(text: "{\($0)}", isToken: true) }
  }

  private func settingChips(_ template: PromptTemplate) -> [Chip] {
    template.settingsSummary.map { Chip(text: $0, isToken: false) }
  }

  private func useChip(_ template: PromptTemplate) -> Chip? {
    guard template.useCount > 0 else { return nil }
    return Chip(text: "used \(template.useCount)×", isToken: false)
  }

  private enum Press {
    case fill
    case launch
  }

  private func pressCurrent(_ press: Press) {
    guard let index = store.templates.selectionIndex, index < rows.count else { return }
    let id = rows[index].template.id
    switch press {
    case .fill: store.send(.templateChosen(id))
    case .launch: store.send(.templateLaunched(id))
    }
  }
}

extension ProjectFeature.TemplatePickerScope {
  var isProjectEquivalent: Bool {
    self == .project
  }
}
