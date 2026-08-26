import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The one question a new workspace has to ask: which agent runs its loops.
///
/// Page 4 of the tour, alone, in the new window. The other three pages taught what a loop
/// is and what the graph does — learned once, in whichever workspace came first. This one
/// is different because the *answer* is per-workspace: `settings.json` lives inside the
/// support directory, so a new workspace starts on the built-in default however the
/// person has configured every other one (see `WorkspaceStarter`).
///
/// Three deliberate departures from the tour's version of this page:
///
/// - **It names the workspace.** A workspace opens in its own window, often on another
///   screen, so a dialog that doesn't say which window is asking is a dialog you have to
///   go and identify.
/// - **It preselects what the creating workspace uses**, not the built-in default. The
///   common case is "the same as I already use", and that should be one button, not a
///   re-decision.
/// - **No dots, no Back.** A one-step wizard is a dialog.
struct WorkspaceStarterView: View {
  @Bindable var store: StoreOf<AppFeature>
  let workspace: Workspace
  let suggested: CLISessionBackendKind

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        HStack(spacing: 7) {
          Circle()
            .fill(WorkspaceSwitcherPanel.tint(for: workspace))
            .frame(width: 7, height: 7)
          Text(workspace.name)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
        }
        Spacer()
        Button("Skip") { store.send(.workspaces(.starterDismissed)) }
          .buttonStyle(.plain)
          .foregroundStyle(.white.opacity(0.6))
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)

      VStack(spacing: 14) {
        Text("Which agent runs them here")
          .font(.system(size: 25, weight: .bold))
          .tracking(-0.25)
        Text(
          "This workspace keeps its own default. Starting from what \(store.workspaces.current.name) "
            + "uses — change it any time in Settings, or per loop."
        )
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.65))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 470)

        VStack(spacing: 8) {
          ForEach(CLISessionBackendKind.allCases, id: \.self) { backend in
            row(backend)
          }
        }
        .frame(maxWidth: 440)

        // Same words as the tour's page, and for the same reason: nothing here probes
        // the PATH, so promising that the CLI is present would be the dialog making it
        // up.
        Text(
          "The CLI must be installed and on your PATH — GraphCode launches it, it doesn't "
            + "bundle it."
        )
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 440)
      }
      .padding(.top, 22)
      .padding(.horizontal, 32)

      Spacer(minLength: 20)

      HStack {
        Text("Only asked once per workspace")
          .font(.system(size: 11))
          .foregroundStyle(.white.opacity(0.35))
        Spacer()
        Button("Start Working") { store.send(.workspaces(.starterDismissed)) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
      }
      .padding(20)
    }
    .frame(width: 560, height: 560)
  }

  /// `OnboardingBackendPage`'s row, verbatim in its metrics — this is the same decision
  /// in the same words, and it should be the same object. The one addition is the
  /// "same as …" badge, which is what makes the preselection legible as a suggestion
  /// rather than an arbitrary starting point.
  private func row(_ backend: CLISessionBackendKind) -> some View {
    let isSelected = store.workspaces.starterBackend == backend
    return Button {
      store.send(.workspaces(.starterBackendPicked(backend)))
    } label: {
      HStack(spacing: 13) {
        Text(">_")
          .font(.system(size: 13, weight: .medium, design: .monospaced))
          .foregroundStyle(.white.opacity(0.6))
          .frame(width: 30, height: 30)
          .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 7) {
            Text(backend.displayName).font(.system(size: 13, weight: .semibold))
            OnboardingBackendPage.capabilityBadge(backend)
            if backend == suggested {
              Text("SAME AS \(store.workspaces.current.name.uppercased())")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.vertical, 1)
                .padding(.horizontal, 5)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
            }
          }
          Text(OnboardingBackendPage.blurb(backend))
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
        }
        Spacer(minLength: 0)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Theme.paneFocusTint : .white.opacity(0.25))
      }
      .padding(.vertical, 13)
      .padding(.horizontal, 15)
      .background(
        isSelected ? Theme.paneFocusTint.opacity(0.1) : Color.white.opacity(0.03),
        in: RoundedRectangle(cornerRadius: 11)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .stroke(
            isSelected ? Theme.paneFocusTint : .white.opacity(0.08),
            lineWidth: isSelected ? 1.5 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
