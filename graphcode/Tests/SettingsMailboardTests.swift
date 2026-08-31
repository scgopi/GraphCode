import Foundation
import Testing

@testable import graphcode

/// The Mailboard's boot decision in the app: the ramp answers for an install that has
/// never chosen, a recorded choice outranks it from then on, and the resolved bit
/// reaches `settings.json` only when it differs — the daemon enforces the setting out
/// of the file and cannot see ramps or `UserDefaults`.
@Suite
struct SettingsMailboardTests {
  private func resolution(
    loaded: Bool, choice: Bool?, rampedOn: Bool
  ) -> SettingsModel.MailboardResolution {
    SettingsModel.resolvesMailboard(
      loaded: loaded, explicitChoice: choice, rampedOn: rampedOn)
  }

  @Test
  func theRampDecidesForAnInstallThatHasNeverChosen() {
    // First launch on a beta install: the ramp's answer has to reach the file, or the
    // daemon — which never sees the ramp — keeps the board off.
    #expect(
      resolution(loaded: false, choice: nil, rampedOn: true)
        == SettingsModel.MailboardResolution(
          enabled: true, fileNeedsWrite: true, showsSwitch: true))
    // A stable install the ramp hasn't reached boots off, and the file already
    // agrees, so nothing is written.
    #expect(
      resolution(loaded: false, choice: nil, rampedOn: false)
        == SettingsModel.MailboardResolution(
          enabled: false, fileNeedsWrite: false, showsSwitch: false))
  }

  @Test
  func aRecordedChoiceOutranksTheRamp() {
    // An explicit on survives the ramp never — or no longer — offering it, and the
    // switch stays offered so the choice can always be undone.
    #expect(
      resolution(loaded: true, choice: true, rampedOn: false)
        == SettingsModel.MailboardResolution(
          enabled: true, fileNeedsWrite: false, showsSwitch: true))
    // An explicit off survives the ramp turning everyone on.
    #expect(
      resolution(loaded: false, choice: false, rampedOn: true)
        == SettingsModel.MailboardResolution(
          enabled: false, fileNeedsWrite: false, showsSwitch: true))
  }

  @Test
  func anAgreeingFileIsNotRewritten() {
    // Every launch of a settled install resolves the same answer; rewriting identical
    // bytes would be churn.
    #expect(
      resolution(loaded: true, choice: nil, rampedOn: true)
        == SettingsModel.MailboardResolution(
          enabled: true, fileNeedsWrite: false, showsSwitch: true))
  }

  @Test
  func aRampPulledToZeroReachesTheFile() {
    // The kill-switch posture: the ramp drops to 0 under a choice-less install whose
    // file still says on — the app is the only writer that can resolve this, and the
    // switch goes away with it.
    #expect(
      resolution(loaded: true, choice: nil, rampedOn: false)
        == SettingsModel.MailboardResolution(
          enabled: false, fileNeedsWrite: true, showsSwitch: false))
  }
}
