import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The new-loop dialog (docs/06-ux-terminals.md#node-configuration-panel): what kind of
/// loop, then the fields that kind actually needs, then the bindings every kind shares,
/// then a plain sentence saying what Create will do.
///
/// Rebuilt around three fixes, each of which was a real defect rather than a taste:
///
/// - **The type control only named the types.** Four segments reading "Goal-based /
///   Time-based / Turn-based / Proactive" ask the reader to already know the taxonomy
///   the dialog exists to teach, and read as a filter rather than as the mode switch
///   they are. Now `LoopTypeChooser` — tiles that say what each type does.
/// - **The form documented itself in placeholders**, which vanish on the first keystroke,
///   exactly when the person typing needs them. Help text now sits under each field
///   (`DraftField`), which macOS `Form` cannot do — hence the hand-laid `VStack` and the
///   loss of `.formStyle(.columns)`, whose right-aligned label column is also what
///   squeezed "Measured by" until its own placeholder truncated.
/// - **Two of the four types had nothing to fill in.** A turn-based loop had no task
///   field at all, so its session opened bare; a composite was one sentence and no
///   fields, so nothing about it could be decided in the dialog that creates it.
///
/// A view of its own rather than a property on `ProjectCanvasView`: the Graph overview
/// presents the same form for the global graph's own triggers, and two copies of a form
/// whose fields are load-bearing would drift.
struct NodeDraftForm: View {
  @Bindable var store: StoreOf<ProjectFeature>

  /// Whether this graph's repository lives on another machine — see
  /// `RemoteProjectLocation`. Drives which bindings the form can honestly offer.
  private var isRemoteProject: Bool {
    RemoteProjectLocation.parse(projectPath: store.graph.project.path) != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      if store.templates.isPickerOpen {
        // The picker replaces the body while it is open — the same sheet, not a
        // second window (PROMPT_TEMPLATES.md § Picker).
        TemplatePickerView(store: store)
      } else {
        header
        appliedState
        LoopTypeChooser(selection: $store.draftLoopType)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            typeFields
            Divider().overlay(Color.white.opacity(0.08))
            runsAs
            NodeDraftRecap(draft: store.draft, worktree: store.draftWorktree)
          }
          .padding(.bottom, 4)
        }
        .scrollIndicators(.automatic)
        footer
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 18)
    // Flexible on both axes so the sheet can be dragged larger — a fixed frame is what
    // pinned it. The ideal height grew with the chooser, which is a band and a rule
    // taller now that Main sits above the grid.
    .frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity)
    .frame(minHeight: 560, idealHeight: 760, maxHeight: .infinity)
    .background(Theme.sheet)
    // Save-as-template's sheet: the dialog is already a sheet, and one prompt plus a
    // name and a destination is all the ceremony a save needs.
    .sheet(item: $store.templates.pendingSave) { _ in
      TemplateSaveSheet(store: store)
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("New loop").font(.system(size: 16, weight: .semibold))
        Text("in \(store.graph.project.name)")
          .font(.system(size: 12))
          .foregroundStyle(.white.opacity(0.45))
      }
      Spacer(minLength: 8)
      templatesButton
    }
  }

  /// Action blue, never a loop-type hue — templates are chrome, not taxonomy, and
  /// there is no sixth colour in this feature (PROMPT_TEMPLATES.md § What changes
  /// in the New loop dialog).
  private var templatesButton: some View {
    Button {
      store.send(.templatesButtonTapped)
    } label: {
      HStack(spacing: 6) {
        Text("Templates")
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(Color(red: 0.706, green: 0.843, blue: 1.0).opacity(0.95))
        Text("⌘T")
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.white.opacity(0.6))
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        Theme.paneFocusTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(Theme.paneFocusTint.opacity(0.4), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .keyboardShortcut("t", modifiers: .command)
  }

  /// The applied template, stated — the chip, the plain-words shape sentence, the
  /// tokens still to fill. The dialog must never gain a shape silently.
  @ViewBuilder
  private var appliedState: some View {
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
          HStack(alignment: .top, spacing: 4) {
            Text(shapeSentence(applied))
              .font(.system(size: 11.5))
              .foregroundStyle(.white.opacity(0.75))
              .fixedSize(horizontal: false, vertical: true)
            Button("Undo the shape") { store.send(.templateShapeUndone) }
              .buttonStyle(.plain)
              .font(.system(size: 11.5, weight: .semibold))
              .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9))
          }
        }
        if !store.unfilledTokens.isEmpty {
          HStack(spacing: 5) {
            Text("Fill in:")
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

  /// The shape in words, exactly the strip's promise: what type it made the loop
  /// and what it set. "Undo the shape to keep just the prompt" rides on it.
  private func shapeSentence(_ applied: ProjectFeature.AppliedTemplate) -> AttributedString {
    var text = AttributedString("This template")
    if applied.setFields.contains(.shape) || applied.shape != nil {
      text += AttributedString(" makes it a \((applied.shape ?? .sketch).displayName) loop")
    }
    let settings: [String] = [
      applied.setFields.contains(.doneCheck) ? "sets a done check" : nil,
      applied.setFields.contains(.cadence) ? "sets a cadence" : nil,
      applied.setFields.contains(.pausesBeforeWritesOnly) ? "pauses only before writes" : nil,
      applied.setFields.contains(.branch) ? "sets a worktree" : nil,
      applied.setFields.contains(.metric) ? "tracks a metric" : nil,
      applied.setFields.contains(.backend) ? "names the agent" : nil,
      applied.setFields.contains(.subGraph) ? "carries its loops" : nil,
    ].compactMap { $0 }
    if !settings.isEmpty {
      if text.characters.count > "This template".count { text += AttributedString(" and") }
      text += AttributedString(" " + Self.list(settings))
    }
    text += AttributedString(".")
    return text
  }

  /// "a", "a and b", "a, b and c" — the spec's sentence reads as a sentence, and
  /// three settings joined with two "and"s does not.
  static func list(_ parts: [String]) -> String {
    guard let last = parts.last else { return "" }
    guard parts.count > 1 else { return last }
    return parts.dropLast().joined(separator: ", ") + " and " + last
  }

  @ViewBuilder
  private var typeFields: some View {
    switch store.draftLoopType {
    case .sketch: SketchDraftFields(store: store)
    case .goalBased: GoalDraftFields(store: store)
    case .timeBased: TimedDraftFields(store: store)
    case .turnBased: TurnDraftFields(store: store)
    case .composite: CompositeDraftFields(store: store)
    }
  }

  /// The bindings every type shares. Worktrees are hidden for a remote project —
  /// creating one would have to happen on the remote host, which v1 doesn't do
  /// (docs/09-remote-repositories.md) — and for the global graph, whose loops belong to
  /// no repository at all.
  private var runsAs: some View {
    VStack(alignment: .leading, spacing: 10) {
      DraftSectionCaption(text: "RUNS AS")
      HStack(alignment: .top, spacing: 10) {
        DraftField(
          label: "Agent", fromTemplate: store.templateSetFields.contains(.backend)
        ) {
          Picker("", selection: $store.draftBackend) {
            ForEach(CLISessionBackendKind.allCases, id: \.self) { backend in
              Text(backend.displayName).tag(backend)
            }
          }
          .labelsHidden()
        }
        if !isRemoteProject && !store.graph.isGlobal {
          DraftField(
            label: "Branch", fromTemplate: store.templateSetFields.contains(.branch)
          ) {
            Picker("", selection: $store.draftWorktree) {
              Text("This folder").tag(ProjectFeature.WorktreeSelection.none)
              ForEach(store.availableWorktrees) { worktree in
                Text(worktree.branch).tag(ProjectFeature.WorktreeSelection.existing(worktree))
              }
              Text("New branch…").tag(ProjectFeature.WorktreeSelection.newBranch)
            }
            .labelsHidden()
          }
        }
      }
      if store.draftWorktree == .newBranch {
        DraftTextField(placeholder: "branch name", text: $store.draftBranch, isMono: true)
      }
      if store.draftLoopType == .sketch {
        Text(
          "Main loops don't cut a worktree by default — most of them read rather than "
            + "write. Pick a branch here if this one will."
        )
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.6))
        .fixedSize(horizontal: false, vertical: true)
      }
      // The capability logic stays exactly where it was — this only shows what it says.
      if !store.draftBackend.canHost(store.draftLoopType) {
        DraftWarningNote(
          text: BackendPicker.unsupportedReason(
            backend: store.draftBackend, loopType: store.draftLoopType))
      }
    }
    .onChange(of: store.draftLoopType) { _, newValue in
      // Changing the type can invalidate a backend that was fine a moment ago. Falling
      // back beats leaving an impossible pairing selected and refusing to submit with no
      // explanation of which field is at fault. Same rule `BackendPicker` applied.
      if !store.draftBackend.canHost(newValue) {
        store.draftBackend = CLISessionBackendKind.hosting(newValue).first ?? .claudeCode
      }
    }
  }

  private var footer: some View {
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
      // `draft.isValid` already knows why the button is off. Saying it beats a disabled
      // control with no explanation, which is the version people file bugs about.
      if let notice = store.templates.saveNotice {
        HStack(spacing: 4) {
          Text(noticePath(notice))
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.middle)
          Button(notice.otherOffer) { store.send(.templateRelocationTapped) }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.549, green: 0.773, blue: 1.0).opacity(0.9))
          // The line is quiet, not permanent: it shares this slot with the reason
          // Create is disabled, and staying forever would mean the dialog never
          // explains itself again.
          Button {
            store.send(.templateSaveNoticeDismissed)
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 8.5, weight: .semibold))
              .foregroundStyle(.white.opacity(0.45))
          }
          .buttonStyle(.plain)
        }
      } else if let reason = disabledReason {
        Text(reason)
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.62))
          .lineLimit(1)
      }
      createButton
    }
  }

  /// A prompt written is a template waiting to happen — the design's second save
  /// entry point (the first being a loop's context menu, the third a composite's).
  private var hasBriefToSave: Bool {
    !store.currentBriefText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || store.draftLoopType == .composite
  }

  /// "~/.graphcode/templates/review-diff.md" or the project's own — the quiet
  /// line states the path so the human knows where the file went.
  private func noticePath(_ notice: ProjectFeature.TemplateSaveNotice) -> String {
    "Saved to " + TemplateSavePath.display(of: notice.template)
  }

  private var createButton: some View {
    Button {
      store.send(.createNodeConfirmed)
    } label: {
      HStack(spacing: 6) {
        Text(createLabel)
          .font(.system(size: 13, weight: .semibold))
        Text("⏎").font(.system(size: 11, design: .monospaced)).opacity(0.7)
      }
      .foregroundStyle(isCreateEnabled ? .white : .white.opacity(0.42))
      .padding(.horizontal, 14)
      .frame(height: 32)
      .background(
        Theme.paneFocusTint.opacity(isCreateEnabled ? 1 : 0.28),
        in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.defaultAction)
    // docs/08 wants an under-specified node to be structurally awkward, not just
    // discouraged — so the button is off until the draft actually means something.
    // A template's unfilled `{token}` is the same kind of hole: Start stays off
    // until the brief is whole (PROMPT_TEMPLATES.md § What a template carries).
    .disabled(!isCreateEnabled)
  }

  private var isCreateEnabled: Bool {
    store.draft.isValid && !store.draftBlocksOnTokens
  }

  /// The primary button says what Create will actually do — and when a template
  /// shaped the draft, it says the shape the draft took on.
  private var createLabel: String {
    switch store.draftLoopType {
    case .sketch: "Start"
    case .composite: "Create & open"
    case .goalBased: store.templates.applied?.shape != nil ? "Create goal loop" : "Create loop"
    case .timeBased: store.templates.applied?.shape != nil ? "Create timed loop" : "Create loop"
    case .turnBased: store.templates.applied?.shape != nil ? "Create turn loop" : "Create loop"
    }
  }

  /// Which field is missing, in the words of the thing that is missing.
  private var disabledReason: String? {
    guard !store.draft.isValid || store.draftBlocksOnTokens else { return nil }
    if let first = store.unfilledTokens.first {
      return "Fill in {\(first)} to continue"
    }
    guard store.draftBackend.canHost(store.draftLoopType) else {
      return "This agent can't host this kind of loop"
    }
    switch store.draftLoopType {
    case .sketch: return nil  // Never incomplete — an empty sketch is a valid one.
    case .goalBased: return "Say what done looks like to continue"
    case .timeBased: return "Say what to do each time to continue"
    case .turnBased: return "Add a first instruction to continue"
    case .composite: return "Name it to continue"
    }
  }
}
