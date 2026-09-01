import Foundation
import Testing

@testable import graphcode

/// The Artifactory's boot decision in the app: the ramp answers for an install that has
/// never chosen, a recorded choice outranks it from then on, and the resolved bit
/// reaches `settings.json` only when it differs — the daemon enforces the setting out
/// of the file and cannot see ramps or `UserDefaults`.
@Suite
struct SettingsArtifactoryTests {
  private func resolution(
    loaded: Bool, choice: Bool?, rampedOn: Bool
  ) -> SettingsModel.ArtifactoryResolution {
    SettingsModel.resolvesArtifactory(
      loaded: loaded, explicitChoice: choice, rampedOn: rampedOn)
  }

  @Test
  func theRampDecidesForAnInstallThatHasNeverChosen() {
    // First launch on a beta install: the ramp's answer has to reach the file, or the
    // daemon — which never sees the ramp — keeps the board off.
    #expect(
      resolution(loaded: false, choice: nil, rampedOn: true)
        == SettingsModel.ArtifactoryResolution(
          enabled: true, fileNeedsWrite: true))
    // Should the ramp ever be pulled, an install that never chose boots off, and a
    // file that already agrees is left alone.
    #expect(
      resolution(loaded: false, choice: nil, rampedOn: false)
        == SettingsModel.ArtifactoryResolution(
          enabled: false, fileNeedsWrite: false))
  }

  @Test
  func aRecordedChoiceOutranksTheRamp() {
    // An explicit on survives the ramp being pulled back.
    #expect(
      resolution(loaded: true, choice: true, rampedOn: false)
        == SettingsModel.ArtifactoryResolution(
          enabled: true, fileNeedsWrite: false))
    // An explicit off survives the ramp turning everyone on.
    #expect(
      resolution(loaded: false, choice: false, rampedOn: true)
        == SettingsModel.ArtifactoryResolution(
          enabled: false, fileNeedsWrite: false))
  }

  @Test
  func anAgreeingFileIsNotRewritten() {
    // Every launch of a settled install resolves the same answer; rewriting identical
    // bytes would be churn.
    #expect(
      resolution(loaded: true, choice: nil, rampedOn: true)
        == SettingsModel.ArtifactoryResolution(
          enabled: true, fileNeedsWrite: false))
  }

  @Test
  func aRampPulledToZeroReachesTheFile() {
    // The kill-switch posture: the ramp drops to 0 under a choice-less install whose
    // file still says on — the app is the only writer that can resolve this. The
    // switch stays: it is a setting, and a person can turn the board back on.
    #expect(
      resolution(loaded: true, choice: nil, rampedOn: false)
        == SettingsModel.ArtifactoryResolution(
          enabled: false, fileNeedsWrite: true))
  }
}
