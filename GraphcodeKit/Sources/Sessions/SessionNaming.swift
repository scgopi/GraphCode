import Foundation

/// Whether a loop's session is named after the loop's title rather than its node id —
/// `FeatureRamps.sessionNaming`, mirrored here because `graphcoded` and the CLI have no
/// ramps of their own. Off, every backend launches exactly as it did before.
public enum SessionNaming {
  /// Wins over `rampFlag`, for tests only. Task-local so one test's ramp never reaches
  /// another suite's argv assertions running in parallel.
  @TaskLocal static var rampOverride: Bool?

  public static var rampFlag: URL {
    SupportDirectory.url.appendingPathComponent("session-naming.on")
  }

  public static var isRampedOn: Bool {
    rampOverride
      ?? (!NodRuntimeLocator.isTestHost && FileManager.default.fileExists(atPath: rampFlag.path))
  }

  /// The name a session for `title` launches under, or `nil` while the ramp is off.
  public static func displayName(forTitle title: String) -> String? {
    isRampedOn ? title : nil
  }
}
