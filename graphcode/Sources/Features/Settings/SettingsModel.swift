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

  /// The user's explicit Mailroom flip, kept apart from `settings` on purpose: the
  /// ramp decides what an install that has never chosen boots on, but once a human
  /// has flipped the switch the ramp never overrides them — the way `updateChannel`
  /// does for updates.
  static let mailroomChoiceDefaultsKey = "mailroomChoice"

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

  /// The Mailroom as a switch, following `betaUpdates`' shape — but the daemon
  /// enforces this one, so a flip writes `mailroomEnabled` into `settings` (which
  /// saves the file the daemon reads) *and* records the explicit choice that then
  /// outranks the ramp for good.
  var mailroomEnabled: Bool {
    didSet {
      UserDefaults.standard.set(mailroomEnabled, forKey: Self.mailroomChoiceDefaultsKey)
      settings.mailroomEnabled = mailroomEnabled
    }
  }

  private init() {
    let loaded = GraphcodeSettingsStore.load()
    let mailroom = Self.resolvesMailroom(
      loaded: loaded.mailroomEnabled,
      explicitChoice:
        UserDefaults.standard.object(forKey: Self.mailroomChoiceDefaultsKey) as? Bool,
      rampedOn: FeatureRamps.isEnabled(.mailroom))
    var booted = loaded
    booted.mailroomEnabled = mailroom.enabled
    settings = booted
    // The assignment above is this property's initial value, so no observer ran: the
    // ramp-resolved bit is saved by hand, and only when it differs from the file.
    if mailroom.fileNeedsWrite {
      GraphcodeSettingsStore.save(booted)
    }
    mailroomEnabled = mailroom.enabled
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    betaUpdates =
      UpdateChannel.channel(
        for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
      == .beta
  }

  /// The Mailroom's boot decision, separated so tests can pin it without touching
  /// `UserDefaults`, the settings file, or the bundle.
  ///
  /// An install that has never chosen boots on the ramp's answer — on everywhere since
  /// the board shipped, with `ramps.json` kept as the kill switch — and that answer has
  /// to reach `~/.graphcode/settings.json` when it differs, because the daemon enforces
  /// `mailroomEnabled` out of the file and cannot see ramps or `UserDefaults`. A
  /// recorded choice outranks the ramp from then on. The switch itself is always
  /// offered: it is a setting now, not a beta gate, and a person who finds the board
  /// too much turns it off here. Rewriting a file that already agrees is churn.
  static func resolvesMailroom(
    loaded: Bool, explicitChoice: Bool?, rampedOn: Bool
  ) -> MailroomResolution {
    let enabled = explicitChoice ?? rampedOn
    return MailroomResolution(enabled: enabled, fileNeedsWrite: enabled != loaded)
  }

  struct MailroomResolution: Equatable {
    var enabled: Bool
    var fileNeedsWrite: Bool
  }
}
