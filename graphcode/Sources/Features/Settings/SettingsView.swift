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
      // Resizable both ways: 560 is the width the window opens at, and the floor
      // sits at 480 — the grouped form's captions wrap, so narrow just means taller.
      .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity)
      .padding(.vertical, 4)
      .background(SettingsWindowResizability())
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

        Picker("OpenCode", selection: $model.settings.openCodePermissions) {
          ForEach(GraphcodeSettings.OpenCodePermissions.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Text(model.settings.openCodePermissions.explanation)
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
          "What each loop is doing, at the top of its rail, read from the session's own "
            + "transcript. Costs nothing."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Let a model write the summaries (experimental)",
          isOn: $model.settings.summaryUsesModel
        )
        .disabled(!model.settings.summarisesLoops)
        Text("One short call to your backend's CLI per change. The part that costs money.")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Visualise what loops did (experimental)",
          isOn: $model.settings.visualisesSummaries
        )
        .disabled(!model.settings.summarisesLoops)
        Text(
          "Draws each finished pass as a flowchart or a table, under the summary in the "
            + "loop's rail. One short call to your backend's CLI per pass — not per "
            + "change — and most passes are drawn as nothing, because most passes have no "
            + "shape worth a diagram. The Mermaid is copyable."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Daemon heartbeat (experimental)",
          isOn: $model.settings.daemonHeartbeatEnabled)
        Text(
          "The daemon drives time-based loops on its own timer. On, new timed loops "
            + "default to the heartbeat (pick \"Itself, with /loop\" in the form, or "
            + "omit --heartbeat in the CLI, for the classic model). Off, existing "
            + "experimental heartbeat loops fall silent immediately; nothing is ever "
            + "converted. Codex and OpenCode always use daemon recurrence."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Keep this Mac awake while loops run (experimental)",
          isOn: $model.settings.keepsMacAwakeWhileLoopsRun)
        Text(
          "The daemon holds the same idle-sleep assertion as `caffeinate -i` while any "
            + "loop is running, and drops it the moment the last one stops. Unattended "
            + "loops stop stalling on a machine that went to sleep. It does not keep the "
            + "display on, and it does not override closing the lid or choosing Sleep."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle(
          "Export and import loops",
          isOn: $model.settings.sharesLoops)
        Text(
          "Right-click a loop — on the canvas or in the sidebar — to package it, its "
            + "child loops and their session memory into a zip, and to import such a "
            + "bundle back in. Also enables the CLI's export/import verbs."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        // The `artifactory` ramp decides whether the switch is offered at all; the
        // daemon-side bit it drives lives in `artifactoryEnabled` (`GraphcodeSettings`),
        // which the model writes the ramp's answer to at launch.
        if model.showsArtifactory {
          Toggle("Artifactory", isOn: $model.artifactoryEnabled)
          Text(
            "Loops share a message board — a note dropped for whoever comes next, "
              + "discoverable by loops that didn't exist when it was written — "
              + "alongside the addressed `node send` and edges. The daemon enforces "
              + "this: off, it refuses every artifactory command. Beta installs start "
              + "on; a flip here is remembered even if the rollout later changes."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
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

/// Makes the Settings window actually resizable, because the SwiftUI spelling doesn't.
///
/// `.windowResizability(.contentMinSize)` on the `Settings` scene is silently ignored
/// here: the window materialises with styleMask 32771 — titled + closable +
/// fullSizeContentView, no `.resizable` bit — measured on macOS 26.5 with the modifier
/// in place. So the bit is set the AppKit way, from a zero-sized view that rides in the
/// content's background purely to get its hands on the window.
///
/// Setting it once is not enough: SwiftUI re-asserts the scene's styleMask after the
/// window appears and strips the bit again (also measured). Hence the observation —
/// whenever the bit goes missing it is re-inserted, one hop later so the mask isn't
/// mutated from inside its own change notification. Content min/max sizes are left
/// alone: SwiftUI derives those from the `.frame` above and they are already right —
/// the mask is the only thing it gets wrong.
private struct SettingsWindowResizability: NSViewRepresentable {
  final class HookView: NSView {
    private var observation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      observation = nil
      guard let window else { return }
      window.styleMask.insert(.resizable)
      observation = window.observe(\.styleMask) { window, _ in
        guard !window.styleMask.contains(.resizable) else { return }
        DispatchQueue.main.async { window.styleMask.insert(.resizable) }
      }
    }
  }

  func makeNSView(context: Context) -> NSView { HookView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

#Preview {
  SettingsView()
}
