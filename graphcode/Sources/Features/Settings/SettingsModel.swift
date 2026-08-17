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

  var settings: GraphcodeSettings {
    didSet {
      guard settings != oldValue else { return }
      GraphcodeSettingsStore.save(settings)
    }
  }

  /// The update channel as a switch (#36). It is persisted in the shared settings file
  /// and mirrored to the update client's legacy `UserDefaults` override.
  var betaUpdates: Bool {
    didSet {
      guard betaUpdates != oldValue else { return }
      settings.betaUpdates = betaUpdates
      UserDefaults.standard.set(betaUpdates ? "beta" : "stable", forKey: "updateChannel")
    }
  }

  private init() {
    let persisted = GraphcodeSettingsStore.load()
    settings = persisted
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    betaUpdates =
      persisted.betaUpdates
      || UpdateChannel.channel(
        for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
        == .beta
  }
}
