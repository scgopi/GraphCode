import GraphcodeKit
import SwiftUI

/// The backend picker, filtered by capability rather than assuming every backend can
/// host every loop type — docs/04-cli-backends.md#clisessionbackend-protocol asks for
/// exactly this refusal, and docs/07-roadmap.md#phase-5--multi-backend makes it the
/// visible half of the phase.
///
/// Unsupported backends are shown disabled rather than hidden. Hiding them would leave a
/// human wondering whether graphcode has heard of Codex at all; showing them greyed out,
/// with the reason underneath, answers the question the picker actually raises.
struct BackendPicker: View {
  @Binding var selection: CLISessionBackendKind
  let loopType: LoopType

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Backend", selection: $selection) {
        ForEach(CLISessionBackendKind.allCases, id: \.self) { backend in
          Text(backend.displayName)
            .tag(backend)
        }
      }

      if !selection.canHost(loopType) {
        Label(unsupportedReason, systemImage: "exclamationmark.triangle")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .onChange(of: loopType) { _, newValue in
      // Changing the loop type can invalidate a backend that was fine a moment ago.
      // Falling back beats leaving an impossible pairing selected and refusing to submit
      // with no explanation of which field is at fault.
      if !selection.canHost(newValue) {
        selection = CLISessionBackendKind.hosting(newValue).first ?? .claudeCode
      }
    }
  }

  private var unsupportedReason: String {
    selection.isSpiked
      ? "\(selection.displayName) can't host a \(loopType.rawValue) loop."
      : "\(selection.displayName) isn't wired up yet — GraphCode can't launch it."
  }
}
