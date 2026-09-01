import ComposableArchitecture
import SwiftUI

/// The dialog's field pattern: label above, field full width, help below.
///
/// The old form used macOS `Form` with `.formStyle(.columns)`, and its right-aligned
/// label column is what pushed "Measured by" into a field so narrow its own placeholder
/// truncated. `Form` also can't put help text *under* a field — so the form documented
/// itself in placeholders, which vanish on the first keystroke, exactly when the person
/// typing needs them. Hand-laid rows fix both.
struct DraftField<Content: View>: View {
  let label: String
  /// The "optional" / "recommended" note beside the label.
  var qualifier: String?
  var help: String?
  /// The template set this field — a 5pt blue dot beside the label, never a lock:
  /// everything a template lands stays editable. See PROMPT_TEMPLATES.md § Applied
  /// state.
  var fromTemplate = false
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if fromTemplate {
          Circle()
            .fill(Theme.paneFocusTint)
            .frame(width: 5, height: 5)
        }
        Text(label)
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(.white.opacity(0.85))
        if let qualifier {
          Text(qualifier)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.56))
        }
        if fromTemplate {
          Text("from template")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.75))
        }
      }
      content()
      if let help {
        Text(help)
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.6))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A field's own box: the shared fill, border, radius and focus ring, so a text field, a
/// prose field and a picker all read as the same control.
struct DraftFieldBox: ViewModifier {
  var isFocused = false
  var minHeight: CGFloat = 34

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 9)
      .padding(.vertical, 7)
      .frame(minHeight: minHeight, alignment: .topLeading)
      .background(Theme.draftField, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            isFocused ? Theme.paneFocusTint : .white.opacity(0.12),
            lineWidth: isFocused ? 1.5 : 1)
      }
      .overlay {
        if isFocused {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Theme.paneFocusTint.opacity(0.18), lineWidth: 3)
            .padding(-1.5)
        }
      }
  }
}

extension View {
  func draftFieldBox(isFocused: Bool = false, minHeight: CGFloat = 34) -> some View {
    modifier(DraftFieldBox(isFocused: isFocused, minHeight: minHeight))
  }
}

/// A one-line text field in the dialog's own clothes.
struct DraftTextField: View {
  let placeholder: String
  @Binding var text: String
  var isMono = false
  /// The picker's ⏎ asks the brief's field to take focus, and `⇥` asks whichever
  /// field holds the next unfilled `{token}`; the field consumes the request by
  /// clearing it, so exactly one field answers.
  var takesFocusRequest: Binding<Bool>? = nil
  /// `⇥` while a token is still unfilled. Answering `true` swallows the key, so the
  /// jump replaces the ordinary focus walk rather than fighting it.
  var onTokenJump: (() -> Bool)? = nil

  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text)
      .textFieldStyle(.plain)
      .font(.system(size: isMono ? 12 : 13, design: isMono ? .monospaced : .default))
      .focused($isFocused)
      .draftFieldBox(isFocused: isFocused)
      .onKeyPress(.tab) { onTokenJump?() == true ? .handled : .ignored }
      .claimingFocus(when: takesFocusRequest, focus: $isFocused)
  }
}

/// A prose field — taller, wrapping, for the fields that hold a sentence rather than a
/// command.
struct DraftProseField: View {
  let placeholder: String
  @Binding var text: String
  /// See `DraftTextField.takesFocusRequest` — the brief is where ⏎ lands the human.
  var takesFocusRequest: Binding<Bool>? = nil
  /// See `DraftTextField.onTokenJump`.
  var onTokenJump: (() -> Bool)? = nil

  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(placeholder, text: $text, axis: .vertical)
      .textFieldStyle(.plain)
      .lineLimit(2...4)
      .font(.system(size: 13))
      .focused($isFocused)
      .draftFieldBox(isFocused: isFocused, minHeight: 54)
      .onKeyPress(.tab) { onTokenJump?() == true ? .handled : .ignored }
      .claimingFocus(when: takesFocusRequest, focus: $isFocused)
  }
}

extension View {
  /// Takes focus whenever the request flips true — on appear *and* while already on
  /// screen, which is what makes `⇥` able to move between two visible fields — and
  /// clears the request so exactly one field answers it.
  fileprivate func claimingFocus(
    when request: Binding<Bool>?, focus: FocusState<Bool>.Binding
  ) -> some View {
    onAppear {
      guard let request, request.wrappedValue else { return }
      focus.wrappedValue = true
      request.wrappedValue = false
    }
    .onChange(of: request?.wrappedValue ?? false) { _, wants in
      guard wants, let request else { return }
      focus.wrappedValue = true
      request.wrappedValue = false
    }
  }
}

/// The section caption over a group of shared fields — `RUNS AS`.
struct DraftSectionCaption: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 11, weight: .bold))
      .tracking(0.6)
      .foregroundStyle(.white.opacity(0.55))
  }
}

/// The amber note under a refused pairing, and the only place in the dialog that goes
/// coloured. Text comes from `BackendPicker.unsupportedReason`, which already says the
/// honest thing.
struct DraftWarningNote: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Circle()
        .fill(Color(red: 1.0, green: 0.624, blue: 0.039))
        .frame(width: 6, height: 6)
        .padding(.top, 4)
      Text(text)
        .font(.system(size: 11.5))
        .foregroundStyle(Color(red: 1.0, green: 0.804, blue: 0.478).opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 7)
    .padding(.horizontal, 9)
    .background(
      Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.1),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(red: 1.0, green: 0.624, blue: 0.039).opacity(0.28), lineWidth: 1)
    }
  }
}

/// The two things the draft's text fields need from the store to make `⇥` walk the
/// unfilled `{token}`s: which field is being asked for focus, and what to do when the
/// key is pressed. Bindings rather than plain values because a field *consumes* its
/// request — exactly one answers each jump.
extension StoreOf<ProjectFeature> {
  func templateFocus(_ field: ProjectFeature.TemplateTokenField) -> Binding<Bool> {
    Binding(
      get: { self.templates.focusRequest == field },
      set: { stillWanted in
        guard !stillWanted, self.templates.focusRequest == field else { return }
        self.send(.templateFocusConsumed)
      })
  }

  /// `true` when the key was ours to take: only while a token is actually unfilled,
  /// so ⇥ is the ordinary focus walk in every other state.
  var tokenJump: () -> Bool {
    {
      guard self.draftBlocksOnTokens else { return false }
      self.send(.templateTokenJumpRequested)
      return true
    }
  }
}
