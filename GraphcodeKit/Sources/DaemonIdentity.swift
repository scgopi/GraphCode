import Foundation

/// What version of itself a daemon is, for the `startup` line in its log — so version
/// skew between a client and the daemon answering it can be read off the two logs
/// rather than guessed (issue #289).
///
/// `graphcoded` is a bare executable: Tuist embeds its Info.plist in the binary, where
/// `Bundle.main` still finds it; a SwiftPM build carries none and says so. The
/// executable's inode identity is what `graphcoded` already watches to notice an
/// upgrade underneath itself, so it is logged beside the version as the tie-breaker.
public enum DaemonIdentity {
  public static var version: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unversioned"
  }

  public static var build: String {
    (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unversioned"
  }
}
