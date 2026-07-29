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
    }
    .formStyle(.grouped)
  }

}

#Preview {
  SettingsView()
}
