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

  /// The update channel as a switch (#36) — app-only, so `UserDefaults` rather than
  /// `GraphcodeSettings`: the daemon never checks for updates, and `UpdateClient` reads
  /// the same `updateChannel` key. Starts on the install's effective channel — a beta
  /// build reads as on — and the first flip writes an explicit override either way.
  var betaUpdates: Bool {
    didSet {
      UserDefaults.standard.set(betaUpdates ? "beta" : "stable", forKey: "updateChannel")
    }
  }

  private init() {
    settings = GraphcodeSettingsStore.load()
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    betaUpdates =
      UpdateChannel.channel(
        for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
      == .beta
  }
}
