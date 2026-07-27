import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The node-configuration panel (docs/06-ux-terminals.md#node-configuration-panel):
/// loop type first, then the fields that type actually needs, then the bindings every
/// type shares. Split out of `ProjectCanvasView` purely for size.
extension ProjectCanvasView {
  var newNodeForm: some View {
    VStack(spacing: 12) {
      Text("New Loop Node").font(.headline)
      Form {
        // Loop type is chosen first and determines the rest of the form, mirroring the
        // taxonomy (docs/06-ux-terminals.md#node-configuration-panel). `.proactive` is
        // absent because a composite's sub-graph editor doesn't exist yet — offering it
        // would be a picker entry that can't produce a node.
        Picker("Type", selection: $store.draftLoopType) {
          Text("Turn-based").tag(LoopType.turnBased)
          Text("Goal-based").tag(LoopType.goalBased)
          Text("Time-based").tag(LoopType.timeBased)
          Text("Proactive").tag(LoopType.proactive)
        }
        .pickerStyle(.segmented)

        TextField("Title", text: $store.draftTitle)

        switch store.draftLoopType {
        case .turnBased:
          TextField("Check", text: $store.draftCheck)
        case .goalBased:
          TextField("Goal — what does done look like?", text: $store.draftGoal)
          TextField("Stop condition (optional shell command)", text: $store.draftPredicate)
            .font(.system(.body, design: .monospaced))
          Text(
            store.draftPredicate.isEmpty
              ? "Without a command, the loop resolves when its session finishes."
              : "graphcoded runs this periodically; exit 0 means the goal is met."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        case .timeBased:
          // No interval field: the cadence goes in the prompt itself, as a `/loop` or
          // `/schedule` directive the session runs on its own (see
          // `LoopNode.triggerPrompt`). The placeholder is the whole documentation.
          TextField("/loop 1h Check for new reports", text: $store.draftPrompt)
        case .proactive:
          // No fields: a composite is built by editing its sub-graph after it exists.
          // Saying so beats an empty section that looks like something failed to load.
          Text(
            "A composite starts empty. Add its loops from the node's own canvas, then "
              + "pilot it once before arming — it can't be armed until you have."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }

        Divider()

        // Every node type also gets a worktree binding and a backend, per
        // docs/06-ux-terminals.md#node-configuration-panel. Optional on purpose: a
        // research or review loop has nothing to isolate.
        Picker("Worktree", selection: $store.draftWorktree) {
          Text("None").tag(ProjectFeature.WorktreeSelection.none)
          ForEach(store.availableWorktrees) { worktree in
            Text(worktree.branch).tag(ProjectFeature.WorktreeSelection.existing(worktree))
          }
          Text("New branch…").tag(ProjectFeature.WorktreeSelection.newBranch)
        }

        if store.draftWorktree == .newBranch {
          TextField("branch name", text: $store.draftBranch)
            .font(.system(.body, design: .monospaced))
        }

        BackendPicker(selection: $store.draftBackend, loopType: store.draftLoopType)
      }
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
    .frame(width: 360)
  }
}
