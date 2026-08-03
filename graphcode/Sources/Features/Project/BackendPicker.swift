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

  /// Why this pairing is refused, and what to do instead.
  ///
  /// It used to say only that the backend "can't host a timeBased loop", which is true and
  /// tells you nothing — you can't tell whether it is a missing feature, a bug, or
  /// something you configured wrongly, and the honest answer is none of those. Each reason
  /// now names the capability that is actually absent and points at the way forward.
  private var unsupportedReason: String {
    Self.unsupportedReason(backend: selection, loopType: loopType)
  }

  /// Why a pairing is refused, and what to do instead. Static because the new-loop
  /// dialog draws the note itself now — one sentence, one place, so the picker and the
  /// dialog can't come to explain the same refusal differently.
  ///
  /// It used to say only that the backend "can't host a timeBased loop", which is true and
  /// tells you nothing — you can't tell whether it is a missing feature, a bug, or
  /// something you configured wrongly, and the honest answer is none of those. Each reason
  /// names the capability that is actually absent and points at the way forward.
  static func unsupportedReason(
    backend selection: CLISessionBackendKind, loopType: LoopType
  ) -> String {
    guard selection.isSpiked else {
      return "\(selection.displayName) isn't wired up yet — GraphCode can't launch it."
    }
    let name = selection.displayName
    switch loopType {
    case .timeBased:
      // graphcode holds no timer of its own: a time-based loop's cadence lives *inside*
      // the session, as a `/loop`-style directive the agent runs on itself. A backend
      // without one would run the prompt once and look like a broken schedule.
      return "\(name) has no way to re-trigger its own session — no /loop or /schedule "
        + "equivalent — so a recurring loop would run once and stop. Claude Code can host "
        + "this one."
    case .goalBased:
      return "\(name) has no goal mode — nothing to run turn after turn against a stop "
        + "condition. Try turn-based, where you judge each turn yourself."
    case .composite:
      return "\(name) has no verified sub-agent fan-out, and a composite is a graph of "
        + "loops running inside one node. Claude Code can host this one."
    case .turnBased:
      return "\(name) can't host a turn-based loop."
    }
  }
}
