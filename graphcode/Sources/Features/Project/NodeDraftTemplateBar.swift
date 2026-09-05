import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The template chrome the New Node dialog grew: the applied-template strip at the
/// top and the two-row footer at the bottom. In its own file because `NodeDraftForm`
/// sits at swiftlint's type-body limit, the same reason `ProjectFeature`'s template
/// verbs live beside it rather than inside it.
extension NodeDraftForm {
  /// The applied template, stated — the chip, the plain-words shape sentence, the
  /// tokens still to fill. The dialog must never gain a shape silently.
  @ViewBuilder
  var appliedState: some View {
    if let applied = store.templates.applied {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          HStack(spacing: 6) {
            Text(applied.name)
              .font(.system(size: 11.5, weight: .semibold))
              .foregroundStyle(Color(red: 0.706, green: 0.843, blue: 1.0).opacity(0.95))
              .lineLimit(1)
            Button {
              store.send(.templateChipRemoved)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove the template — everything it contributed goes")
          }
          .padding(.horizontal, 9)
          .frame(height: 24)
          .background(
            Theme.paneFocusTint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .stroke(Theme.paneFocusTint.opacity(0.45), lineWidth: 1)
          }
          Spacer(minLength: 8)
        }
        if applied.carriesShape {
          // One `Text`, not an `HStack` of a wrapping sentence beside two controls:
          // laid out side by side, the sentence's second line wrapped *under* the
          // button and the clause after it, so "…and sets [Undo the shape] to keep
          // just the prompt. a cadence." is what you actually read. An inline link
          // is the only spelling that flows with the words around it.
          Text(shapeSentence(applied))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.75))
            .fixedSize(horizontal: false, vertical: true)
            .environment(
              \.openURL,
              OpenURLAction { url in
                guard url == Self.undoShapeURL else { return .systemAction }
                store.send(.templateShapeUndone)
                return .handled
              })
        }
        if let prompt = store.unfilledTokenPrompt {
          HStack(spacing: 5) {
            Text(prompt)
              .font(.system(size: 11))
              .foregroundStyle(.white.opacity(0.55))
            ForEach(store.unfilledTokens, id: \.self) { token in
              Text("{\(token)}")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color(red: 0.812, green: 0.902, blue: 1.0))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                  Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.18),
                  in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.4), lineWidth: 1)
                }
            }
          }
        }
      }
    }
  }

  /// The link target `Undo the shape` carries. A made-up scheme nothing registers,
  /// intercepted by the strip's own `OpenURLAction` — the price of an inline link in
  /// a `Text`, and cheaper than the layout an `HStack` of controls produced.
  static let undoShapeURL = URL(string: "graphcode://undo-template-shape")

  /// The shape in words, exactly the strip's promise: "This template makes it a
  /// **Goal** loop and sets a done check and a worktree. **Undo the shape** to keep
  /// just the prompt." One shared verb — the design's sentence says "sets a done
  /// check and a worktree", not "sets … and sets …".
  func shapeSentence(_ applied: ProjectFeature.AppliedTemplate) -> AttributedString {
    var text = AttributedString("This template")
    if applied.setFields.contains(.shape) || applied.shape != nil {
      text += AttributedString(" makes it a ")
      var type = AttributedString((applied.shape ?? .sketch).displayName)
      type.inlinePresentationIntent = .stronglyEmphasized
      text += type
      text += AttributedString(" loop")
    }
    let sets: [String] = [
      applied.setFields.contains(.doneCheck) ? "a done check" : nil,
      applied.setFields.contains(.cadence) ? "a cadence" : nil,
      applied.setFields.contains(.branch) ? "a worktree" : nil,
      applied.setFields.contains(.metric) ? "a metric" : nil,
      applied.setFields.contains(.backend) ? "the agent" : nil,
      applied.setFields.contains(.subGraph) ? "its loops" : nil,
    ].compactMap { $0 }
    var clauses: [String] = []
    if !sets.isEmpty { clauses.append("sets " + Self.list(sets)) }
    // The one that isn't a thing being set — it is a rhythm, so it keeps its own verb.
    if applied.setFields.contains(.pausesBeforeWritesOnly) {
      clauses.append("pauses only before writes")
    }
    if !clauses.isEmpty {
      if text.characters.count > "This template".count { text += AttributedString(" and") }
      text += AttributedString(" " + Self.list(clauses))
    }
    text += AttributedString(". ")

    var undo = AttributedString("Undo the shape")
    undo.inlinePresentationIntent = .stronglyEmphasized
    undo.foregroundColor = Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9)
    if let url = Self.undoShapeURL { undo.link = url }
    text += undo
    text += AttributedString(" to keep just the prompt.")
    return text
  }

  /// "a", "a and b", "a, b and c" — the spec's sentence reads as a sentence, and
  /// three settings joined with two "and"s does not.
  static func list(_ parts: [String]) -> String {
    guard let last = parts.last else { return "" }
    guard parts.count > 1 else { return last }
    return parts.dropLast().joined(separator: ", ") + " and " + last
  }

  /// only things that fit.
  var footer: some View {
    VStack(alignment: .leading, spacing: 9) {
      if let notice = store.templates.saveNotice { saveNoticeRow(notice) }
      HStack(spacing: 12) {
        Button("Cancel") { store.send(.cancelNewNodeForm) }
          .buttonStyle(.plain)
          .font(.system(size: 12.5))
          .foregroundStyle(.white.opacity(0.7))
        if hasBriefToSave {
          Button("Save as template…") { store.send(.saveTemplateTapped) }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9))
            .help("Save this brief as a template you can start from next time")
        }
        Spacer(minLength: 8)
        // `draft.isValid` already knows why the button is off. Saying it beats a
        // disabled control with no explanation, which is the version people file bugs
        // about — but it yields width to the button rather than squeezing it.
        if let reason = disabledReason {
          Text(reason)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        createButton
      }
    }
  }

  /// The quiet line after a save: where the file went, the offer of the other
  /// location, and a dismiss. Full width, so nothing here has to truncate.
  func saveNoticeRow(_ notice: ProjectFeature.TemplateSaveNotice) -> some View {
    HStack(spacing: 6) {
      Text(noticePath(notice))
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
        .truncationMode(.middle)
      Button(notice.otherOffer) { store.send(.templateRelocationTapped) }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9))
        .lineLimit(1)
        .fixedSize()
      Spacer(minLength: 6)
      // The line is quiet, not permanent: staying forever would mean the footer never
      // explains why Create is off again.
      Button {
        store.send(.templateSaveNoticeDismissed)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.45))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
  }

  /// A prompt written is a template waiting to happen — the design's second save
  /// entry point (the first being a loop's context menu, the third a composite's).
  var hasBriefToSave: Bool {
    !store.currentBriefText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.draftLoopType == .composite
  }

  /// "~/.graphcode/templates/review-diff.md" or the project's own — the quiet
  /// line states the path so the human knows where the file went.
  func noticePath(_ notice: ProjectFeature.TemplateSaveNotice) -> String {
    "Saved to " + TemplateSavePath.display(of: notice.template)
  }
}
