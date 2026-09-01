import Foundation
import GraphcodeKit
import Observation

/// The app's live view of `GraphcodeSettings`, saved the moment anything changes.
///
/// A shared instance rather than a TCA dependency: these are read by plain SwiftUI views
/// outside any feature's store (the Settings scene, and `AppView` for the window's
/// opacity), and every write has to reach `~/.graphcode/settings.json` because the
/// **daemon** is what actually acts on most of them.
///
/// No explicit "Save" button follows from that: a settings window whose changes only take
/// effect on OK would be lying about where the value lives, since the daemon reads the
/// file fresh for every session it starts.
@Observable
final class SettingsModel {
  static let shared = SettingsModel()

  /// The user's explicit Artifactory flip, kept apart from `settings` on purpose: the
  /// ramp decides what an install that has never chosen boots on, but once a human
  /// has flipped the switch the ramp never overrides them — the way `updateChannel`
  /// does for updates.
  static let artifactoryChoiceDefaultsKey = "artifactoryChoice"

  var settings: GraphcodeSettings {
    didSet {
      guard settings != oldValue else { return }
      GraphcodeSettingsStore.save(settings)
    }
  }

  /// The update channel as a switch (#36) — app-only, so `UserDefaults` rather than
  /// `GraphcodeSettings`: the daemon never checks for updates, and `UpdateClient` reads
  /// the same `updateChannel` key. Starts on the install's effective channel — a beta
  /// build reads as on — and the first flip writes an explicit override either way.
  var betaUpdates: Bool {
    didSet {
      UserDefaults.standard.set(betaUpdates ? "beta" : "stable", forKey: "updateChannel")
    }
  }

  /// Whether the Settings window offers the Artifactory switch at all — the `artifactory`
  /// ramp (`FeatureRamps`), read once at construction for the same reason as
  /// `AppSidebarView.offersCodespaces`: a ramp change applies from the next launch. A
  /// switch a stable install was never offered can't have recorded a choice, so an
  /// install that has chosen keeps its switch even if the ramp later pulls back.
  let showsArtifactory: Bool

  /// The Artifactory as a switch, following `betaUpdates`' shape — but the daemon
  /// enforces this one, so a flip writes `artifactoryEnabled` into `settings` (which
  /// saves the file the daemon reads) *and* records the explicit choice that then
  /// outranks the ramp for good.
  var artifactoryEnabled: Bool {
    didSet {
      UserDefaults.standard.set(artifactoryEnabled, forKey: Self.artifactoryChoiceDefaultsKey)
      settings.artifactoryEnabled = artifactoryEnabled
    }
  }

  private init() {
    let loaded = GraphcodeSettingsStore.load()
    let artifactory = Self.resolvesArtifactory(
      loaded: loaded.artifactoryEnabled,
      explicitChoice:
        UserDefaults.standard.object(forKey: Self.artifactoryChoiceDefaultsKey) as? Bool,
      rampedOn: FeatureRamps.isEnabled(.artifactory))
    var booted = loaded
    booted.artifactoryEnabled = artifactory.enabled
    settings = booted
    // The assignment above is this property's initial value, so no observer ran: the
    // ramp-resolved bit is saved by hand, and only when it differs from the file.
    if artifactory.fileNeedsWrite {
      GraphcodeSettingsStore.save(booted)
    }
    artifactoryEnabled = artifactory.enabled
    showsArtifactory = artifactory.showsSwitch
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    betaUpdates =
      UpdateChannel.channel(
        for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
      == .beta
  }

  /// The Artifactory's boot decision, separated so tests can pin it without touching
  /// `UserDefaults`, the settings file, or the bundle.
  ///
  /// An install that has never chosen boots on the ramp's answer — beta first, stable
  /// only when `ramps.json` raises it — and that answer has to reach
  /// `~/.graphcode/settings.json` when it differs, because the daemon enforces
  /// `artifactoryEnabled` out of the file and cannot see ramps or `UserDefaults`. A
  /// recorded choice outranks the ramp from then on, and keeps the switch offered so
  /// the choice can always be undone. Rewriting a file that already agrees is churn.
  static func resolvesArtifactory(
    loaded: Bool, explicitChoice: Bool?, rampedOn: Bool
  ) -> ArtifactoryResolution {
    let enabled = explicitChoice ?? rampedOn
    return ArtifactoryResolution(
      enabled: enabled, fileNeedsWrite: enabled != loaded,
      showsSwitch: rampedOn || explicitChoice != nil)
  }

  struct ArtifactoryResolution: Equatable {
    var enabled: Bool
    var fileNeedsWrite: Bool
    var showsSwitch: Bool
  }
}
