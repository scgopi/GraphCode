import CryptoKit
import Foundation

/// Staged rollouts ("ramps") with no backend: one static JSON on the site,
/// `https://graphcode.app/ramps.json`, shaped
/// `{ "features": { "codespaces": { "beta": 100, "stable": 0 } } }` — per feature,
/// the percentage of installs it is on for, per update channel. Changing a ramp is a
/// git push to Pages; setting a feature to 0 is the kill switch.
///
/// The client buckets *itself*: a stable hash of a per-install UUID, mod 100, so the
/// same install always lands in the same bucket and a raised percent only ever turns
/// a feature on for more installs — never off-and-on across launches. The hash is
/// SHA-256, not `Hasher`, whose per-process random seed would reshuffle every launch.
///
/// The fetched configuration is cached in `UserDefaults` and read synchronously at
/// render time; the refresh happens once per launch, in the background, and applies
/// from the next read on. No fetch ever *blocks* a feature decision — before the
/// first successful fetch, each feature's baked default percents answer.
enum FeatureRamps {
  struct Configuration: Equatable, Decodable {
    var features: [String: [String: Int]] = [:]
  }

  enum Feature: String {
    case codespaces
    case mailroom

    /// What answers when no ramps.json has ever been fetched (and when the fetch
    /// fails). Kept in step with the *shipped* ramp state: a feature ramped fully on
    /// moves its default up too, so an offline first launch isn't the one place it's
    /// missing — the fetched file stays the kill switch either way.
    var defaultPercents: [String: Int] {
      switch self {
      case .codespaces: return ["beta": 100, "stable": 100]
      case .mailroom: return ["beta": 100, "stable": 100]
      }
    }
  }

  static let rampsURL = URL(string: "https://graphcode.app/ramps.json")!
  static let configurationDefaultsKey = "rampsConfiguration"
  static let installIDDefaultsKey = "rampsInstallID"

  /// The live read the UI uses. Channel comes from the same rule updates follow
  /// (`UpdateChannel`): the override default wins, otherwise the installed version
  /// speaks for itself.
  static func isEnabled(_ feature: Feature) -> Bool {
    let version =
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    let channel = UpdateChannel.channel(
      for: version, override: UserDefaults.standard.string(forKey: "updateChannel"))
    return isEnabled(
      feature, configuration: cachedConfiguration(), channel: channel.rawValue,
      installID: installID())
  }

  /// The pure decision, separated so tests can pin it without touching defaults,
  /// bundles, or the network.
  static func isEnabled(
    _ feature: Feature, configuration: Configuration?, channel: String, installID: String
  ) -> Bool {
    let percents = configuration?.features[feature.rawValue] ?? feature.defaultPercents
    let percent = percents[channel] ?? feature.defaultPercents[channel] ?? 0
    return bucket(installID: installID) < percent
  }

  /// 0...99, stable across launches and processes for one install.
  static func bucket(installID: String) -> Int {
    let digest = SHA256.hash(data: Data(installID.utf8))
    let leading = digest.withUnsafeBytes { $0.load(as: UInt32.self) }
    return Int(leading % 100)
  }

  /// Fetch-and-cache, called once per launch. Ignores the local URL cache so a ramp
  /// change is seen next launch, not whenever the cache expires; failures keep the
  /// last good configuration.
  static func refresh() async {
    var request = URLRequest(url: rampsURL)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.timeoutInterval = 10
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      (try? JSONDecoder().decode(Configuration.self, from: data)) != nil
    else { return }
    UserDefaults.standard.set(data, forKey: configurationDefaultsKey)
  }

  static func cachedConfiguration() -> Configuration? {
    guard let data = UserDefaults.standard.data(forKey: configurationDefaultsKey)
    else { return nil }
    return try? JSONDecoder().decode(Configuration.self, from: data)
  }

  /// Created on first read, then permanent — the identity the bucket is derived
  /// from. Nothing about the install rides along; it exists only so the bucket is
  /// stable.
  static func installID() -> String {
    if let existing = UserDefaults.standard.string(forKey: installIDDefaultsKey) {
      return existing
    }
    let fresh = UUID().uuidString
    UserDefaults.standard.set(fresh, forKey: installIDDefaultsKey)
    return fresh
  }
}
