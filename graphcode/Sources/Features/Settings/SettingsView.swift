import GraphcodeKit
import SwiftUI

/// The Settings window (⌘,) — the things that were hardcoded until someone reasonably
/// wanted them different.
///
/// Every choice states its consequence underneath rather than relying on its name. These
/// settings decide what an agent may do on your machine without asking, and "Don't ask"
/// versus "Bypass all checks" is not a distinction anyone should have to infer from two
/// words.
struct SettingsView: View {
  @Bindable private var model = SettingsModel.shared

  /// One pane, no tabs. There was an Appearance tab, and it held exactly one control — a
  /// window-opacity slider applied as `NSWindow.alphaValue`, which faded the terminal's
  /// text along with everything else. Ghostty's own `background-opacity` does the job
  /// properly (background only, text left crisp) and a terminal's config is where people
  /// look for it, so the setting went rather than being reimplemented here. A tab holding
  /// nothing is worse than no tab.
  var body: some View {
    sessions
      .frame(width: 460)
      .padding(.vertical, 4)
  }

  private var sessions: some View {
    Form {
      Section {
        // Only backends graphcode can actually launch. Codex is absent until it has been
        // spiked end to end — offering it here would set every new loop to something that
        // never starts. See `CLISessionBackendKind.offerableAsDefault`.
        Picker("New loops use", selection: $model.settings.defaultBackend) {
          ForEach(CLISessionBackendKind.offerableAsDefault, id: \.self) { backend in
            Text(backend.displayName).tag(backend)
          }
        }
      } header: {
        Text("Default backend")
      } footer: {
        Text("Which backend a new loop starts on. You can still change it per loop.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("Claude Code", selection: $model.settings.claudePermissionMode) {
          ForEach(GraphcodeSettings.ClaudePermissionMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Text(model.settings.claudePermissionMode.explanation)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Picker("Copilot CLI", selection: $model.settings.copilotPermissions) {
          ForEach(GraphcodeSettings.CopilotPermissions.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Text(model.settings.copilotPermissions.explanation)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Picker("Codex", selection: $model.settings.codexApprovals) {
          ForEach(GraphcodeSettings.CodexApprovals.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Text(model.settings.codexApprovals.explanation)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Permissions")
      } footer: {
        Text(
          "A loop runs whether or not this window is open, so nobody is there to answer a "
            + "permission prompt. A backend left on its own default waits at that prompt "
            + "while the graph reports the loop as running."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Pick a model for each loop", isOn: $model.settings.autoSelectsModel)
      } header: {
        Text("Model")
      } footer: {
        Text(
          "Off, graphcode passes no model and your CLI runs on whatever it's already set "
            + "up to use. On, a loop with no model of its own is routed by its type — "
            + "turn-based loops get a more capable model, time-based polling a faster one. "
            + "A model set on an individual loop always wins either way."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Show the activity strip", isOn: $model.settings.showsActivityStrip)
        Toggle(
          "Summarise what loops are doing (experimental)",
          isOn: $model.settings.summarisesLoops)
        Text(
          "Reads each working session's own transcript and puts what it is doing at the "
            + "top of the loop's rail — and on its card — as a few short lines instead of "
            + "a terminal to scroll. Costs nothing: the words are the agent's own. Off, "
            + "nothing is read and nothing changes. Experimental: a summary is a claim "
            + "about what an agent is trying to do, and it is worth watching on your own "
            + "loops before trusting it."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle("Let a model write the summaries", isOn: $model.settings.summaryUsesModel)
          .disabled(!model.settings.summarisesLoops)
        Text(
          "Sharpens the current line with one short call to your backend's own CLI "
            + "(claude -p, copilot -p, codex exec) on its fast model, per change, over one "
            + "sentence — never the transcript. It runs outside the loop's session, so it "
            + "never lands on that loop's token count, and if it is slow or unavailable "
            + "the agent's own wording stands. This is the only part of summaries that "
            + "costs money."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } footer: {
        Text(
          "A strip along the window's bottom listing passes, hand-offs and state changes "
            + "as they happen. It is derived from the graph rather than stored, so it "
            + "starts empty after a relaunch and fills as things happen."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(
          "Tell sessions they're part of a graph",
          isOn: $model.settings.briefsSessionsAboutTheGraph)
      } footer: {
        Text(
          "Lets a loop create more loops when the work genuinely splits — one per issue, "
            + "one per failing test. Off, a session does the work it was given and never "
            + "creates anything."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Get beta releases", isOn: $model.betaUpdates)
      } header: {
        Text("Updates")
      } footer: {
        Text(
          "On, Check for Updates offers pre-releases as well as stable releases — "
            + "newer features, less soak time. Off, stable releases only. A beta "
            + "install starts on; switching off keeps it as it is until the next "
            + "stable ships."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

}

#Preview {
  SettingsView()
}
