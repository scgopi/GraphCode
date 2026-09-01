import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Save-as-template's sheet — name it, choose where it lands, save. Shared by the
/// dialog's own save button and a card's context menu; the template itself is
/// already built by the reducer, so the sheet edits only the two things a save
/// actually decides.
///
/// Home is the default and the only guaranteed target: a project folder that won't
/// take a `.graphcode/templates` is not offered at all, because a save that silently
/// falls back to home would say one thing and do another.
struct TemplateSaveSheet: View {
  @Bindable var store: StoreOf<ProjectFeature>
  @FocusState private var nameFocused: Bool

  var body: some View {
    if let context = store.templates.pendingSave {
      VStack(alignment: .leading, spacing: 14) {
        Text("Save as template")
          .font(.system(size: 15, weight: .semibold))
        Text(templateSummary)
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)

        DraftField(label: "Name") {
          DraftTextField(
            placeholder: "Review the diff on this branch",
            text: Binding(
              get: { store.templates.pendingSave?.name ?? "" },
              set: {
                if var context = store.templates.pendingSave {
                  context.name = $0
                  store.templates.pendingSave = context
                }
              }
            )
          )
          .focused($nameFocused)
        }

        DraftField(
          label: "Where it lives",
          help:
            "Home is offered in every project. The project folder is what a team "
            + "commits — sharing is a git action, not an app feature."
        ) {
          Picker(
            "",
            selection: Binding(
              get: { store.templates.pendingSave?.scope ?? .home },
              set: {
                if var context = store.templates.pendingSave {
                  context.scope = $0
                  store.templates.pendingSave = context
                }
              }
            )
          ) {
            Text("Home — all projects").tag(TemplateOrigin.home)
            if projectCanSave {
              Text("This project (.graphcode/templates)")
                .tag(TemplateOrigin.project(store.graph.project.path))
            }
          }
          .labelsHidden()
          .pickerStyle(.radioGroup)
          if !projectCanSave {
            Text("This folder can't take a .graphcode/templates, so home is the only option.")
              .font(.system(size: 10.5))
              .foregroundStyle(.white.opacity(0.5))
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        HStack {
          Button("Cancel") { store.send(.saveTemplateCancelled) }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.7))
          Spacer(minLength: 8)
          Button {
            store.send(.saveTemplateConfirmed)
          } label: {
            Text("Save template")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .frame(height: 32)
              .background(Theme.paneFocusTint, in: RoundedRectangle(cornerRadius: 7))
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.defaultAction)
          .disabled(nameIsBlank)
        }
      }
      .padding(20)
      .frame(minWidth: 420, idealWidth: 440)
      .background(Theme.sheet)
      .onAppear {
        if context.name.isEmpty { nameFocused = true }
      }
    }
  }

  private var nameIsBlank: Bool {
    (store.templates.pendingSave?.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// Whether the project folder can actually take a `.graphcode/templates`. SwiftUI
  /// ignores `.disabled` on an individual `Picker` tag, so an unwritable project is
  /// kept out of the list entirely rather than offered and then quietly overruled.
  var projectCanSave: Bool {
    store.templates.pendingSave?.projectCanSave ?? false
  }

  /// What is being saved, in one line — the shape it carries and what it sets.
  private var templateSummary: String {
    guard let context = store.templates.pendingSave else { return "" }
    let label = ProjectFeature.TemplatePickerRow(template: context.template, scope: .home).typeLabel
    let type = context.template.shape == nil ? "a Main loop's brief" : "a \(label) loop"
    let settings = context.template.settingsSummary
    let settingsPart = settings.isEmpty ? "" : ", setting " + settings.joined(separator: ", ")
    let tokens =
      context.template.tokens.isEmpty
      ? ""
      : " Its \(context.template.tokens.count) token\(context.template.tokens.count == 1 ? "" : "s") stay fill-in-at-use."
    return "This saves \(type)\(settingsPart).\(tokens)"
  }
}

/// Presents the save sheet for a save started **outside** the New loop dialog — a
/// loop's context menu, which PROMPT_TEMPLATES.md § Save as template names first.
/// The dialog hosts its own copy while it is open, so this one stands down then:
/// two `.sheet`s bound to the same item present nothing at all.
struct TemplateSaveSheetHost: ViewModifier {
  let store: StoreOf<ProjectFeature>

  func body(content: Content) -> some View {
    content.sheet(
      item: Binding(
        get: { store.showingNewNodeForm ? nil : store.templates.pendingSave },
        set: { if $0 == nil, !store.showingNewNodeForm { store.send(.saveTemplateCancelled) } }
      )
    ) { _ in
      TemplateSaveSheet(store: store)
    }
  }
}

/// The quiet line after a save, for saves made with no dialog on screen to put it in:
/// where the file went, and the offer of the other location. Never a modal, and it
/// dismisses itself — see PROMPT_TEMPLATES.md § Storage.
struct TemplateSaveNoticeBar: View {
  let store: StoreOf<ProjectFeature>

  var body: some View {
    if let notice = store.templates.saveNotice, !store.showingNewNodeForm {
      HStack(spacing: 8) {
        Text("Saved to")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.55))
        Text(TemplateSavePath.display(of: notice.template))
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(.white.opacity(0.75))
          .lineLimit(1)
          .truncationMode(.middle)
        Button(notice.otherOffer) { store.send(.templateRelocationTapped) }
          .buttonStyle(.plain)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9))
        Spacer(minLength: 8)
        Button {
          store.send(.templateSaveNoticeDismissed)
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white.opacity(0.06))
    }
  }
}

/// Where a template's file lives, as a person reads a path. Shared by the dialog's
/// footer line and the canvas notice so both name the same file the same way.
enum TemplateSavePath {
  static func display(of template: PromptTemplate) -> String {
    switch template.origin {
    case .home: return "~/.graphcode/templates/\(template.fileName)"
    case .project(let path): return "\(path)/.graphcode/templates/\(template.fileName)"
    }
  }
}
