import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The node-configuration panel (docs/06-ux-terminals.md#node-configuration-panel):
/// loop type first, then the fields that type actually needs, then the bindings every
/// type shares.
///
/// A view of its own rather than a property on `ProjectCanvasView`: the Graph overview
/// (`GraphOverviewView`) presents the same form for the global graph's own triggers, and
/// two copies of a form whose fields are load-bearing would drift.
struct NodeDraftForm: View {
  @Bindable var store: StoreOf<ProjectFeature>

  /// Whether this graph's repository lives on another machine — see
  /// `RemoteProjectLocation`. Drives which bindings the form can honestly offer.
  private var isRemoteProject: Bool {
    RemoteProjectLocation.parse(projectPath: store.graph.project.path) != nil
  }

  var body: some View {
    VStack(spacing: 12) {
      Text("New Loop Node").font(.headline)

      // Loop type is chosen first and determines the rest of the form, mirroring the
      // taxonomy (docs/06-ux-terminals.md#node-configuration-panel).
      //
      // Outside the `Form` and with its label hidden on purpose. Inside, macOS gives a
      // segmented control the content column only, and four segments don't fit what's
      // left after the label column — the row overflowed the sheet and got clipped at
      // both edges. Out here it spans the full width and reads as what it already
      // behaves like: the dialog's mode switch, not one field among several.
      Picker("Type", selection: $store.draftLoopType) {
        Text("Goal-based").tag(LoopType.goalBased)
        Text("Time-based").tag(LoopType.timeBased)
        Text("Turn-based").tag(LoopType.turnBased)
        Text("Proactive").tag(LoopType.proactive)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Form {
        // The prompt leads and the title follows, below the switch — see there.
        switch store.draftLoopType {
        case .goalBased:
          // Short labels with the explanation in `prompt:`. In a macOS `Form` a
          // `TextField`'s first argument is the *label*, sitting in a column sized to
          // the widest one — so a sentence-long label doesn't read as placeholder text,
          // it drags the whole column past the sheet's edge.
          TextField("Goal", text: $store.draftGoal, prompt: Text("what does done look like?"))
          TextField(
            "Stop when", text: $store.draftPredicate,
            prompt: Text("shell command exits 0 — optional")
          )
          .font(.system(.body, design: .monospaced))
          Text(
            store.draftPredicate.isEmpty
              ? "Without a command, the loop resolves when its session finishes."
              : "graphcoded runs this periodically; exit 0 means the goal is met."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)

          TextField(
            "Measured by", text: $store.draftMetric,
            prompt: Text("how to score progress — a command printing a number")
          )
          .font(.system(.body, design: .monospaced))
          if !store.draftMetric.isEmpty {
            Picker("Better is", selection: $store.draftMetricDirection) {
              Text("higher").tag(MetricDirection.maximize)
              Text("lower").tag(MetricDirection.minimize)
            }
            .pickerStyle(.segmented)
            Text(
              "The loop is told this is how it's measured and runs it as it works; "
                + "the orchestrator samples it once per pass, and a looping edge can "
                + "stop when the number stops improving."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
        case .timeBased:
          // No interval field: the cadence goes in the prompt itself, as a `/loop` or
          // `/schedule` directive the session runs on its own (see
          // `LoopNode.triggerPrompt`). The placeholder is the whole documentation.
          TextField(
            "Prompt", text: $store.draftPrompt,
            prompt: Text("/loop 1h Check for new reports"))
        case .turnBased:
          // One plainly-named field and a one-line caption. This section has been
          // wordier twice ("Verify each turn", then "Review criteria", each with
          // two-sentence captions) and the lesson both times was the same: the form
          // is for entering a value, not for documenting the loop type.
          TextField(
            "Verifier", text: $store.draftCheck,
            prompt: Text("e.g. tests pass and the diff stays small"))
          Text("Pauses after each turn for your review — optional.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .proactive:
          // No fields: a composite is built by editing its sub-graph after it exists.
          // Saying so beats an empty section that looks like something failed to load.
          // Same one-line plain-words treatment as turn-based — "composite", "pilot"
          // and "arm" are this codebase's vocabulary, not the form-filler's.
          Text(
            "A group of loops. Starts empty — open it to add loops, then test-run once before turning it on."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        // Below the prompt and optional, because naming every loop up front was the
        // most tedious field on the form: the prompt is what the human actually has in
        // their head, and a blank title is filled in by the loop's own backend after
        // creation (`claude -p` and friends — see `TitleSuggestionClient`).
        TextField(
          "Title", text: $store.draftTitle,
          prompt: Text("optional — named for you"))

        Divider()

        // Every node type also gets a worktree binding and a backend, per
        // docs/06-ux-terminals.md#node-configuration-panel. Optional on purpose: a
        // research or review loop has nothing to isolate. Hidden for a remote project:
        // worktrees would have to be created on the remote host, which v1 doesn't do
        // (docs/09-remote-repositories.md), and offering a picker whose every choice
        // fails is worse than not asking.
        // Hidden for the global graph too: its loops belong to no repository, so every
        // choice but "None" would be an operation on a directory that doesn't exist.
        if !isRemoteProject && !store.graph.isGlobal {
          Picker("Worktree", selection: $store.draftWorktree) {
            Text("None").tag(ProjectFeature.WorktreeSelection.none)
            ForEach(store.availableWorktrees) { worktree in
              Text(worktree.branch).tag(ProjectFeature.WorktreeSelection.existing(worktree))
            }
            Text("New branch…").tag(ProjectFeature.WorktreeSelection.newBranch)
          }

          if store.draftWorktree == .newBranch {
            TextField("Branch", text: $store.draftBranch, prompt: Text("branch name"))
              .font(.system(.body, design: .monospaced))
          }
        }

        BackendPicker(selection: $store.draftBackend, loopType: store.draftLoopType)
      }
      // `.columns` rather than `.automatic` so the label column is a decision rather
      // than something that changes shape with the presentation context, and
      // `fixedSize` vertically because a `Form` is otherwise greedy — that greed was
      // the empty band between the type picker and the first field.
      .formStyle(.columns)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Cancel") { store.send(.cancelNewNodeForm) }
        Spacer()
        Button("Create") { store.send(.createNodeConfirmed) }
          .keyboardShortcut(.defaultAction)
          // docs/08 wants an under-specified node to be structurally awkward, not just
          // discouraged — so the button is off until the draft actually means something.
          .disabled(!store.draft.isValid)
      }
    }
    .padding(24)
    // Wide enough for four segments across the top and the widest label column any
    // branch of the switch produces. The old 360 fit neither, and a `Form` that doesn't
    // fit its frame doesn't shrink — it overflows and gets clipped at both edges.
    .frame(width: 460)
  }
}
