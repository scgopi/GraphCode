import Foundation

/// Whether this launch should tell someone that workspaces exist.
///
/// The tour teaches a fresh install (`OnboardingWorkspacesPage`). Everyone else was
/// already using GraphCode when workspaces landed, and re-running four pages of tour to
/// deliver one piece of news would be worse than the news — so they get a dialog, once.
///
/// **The rule, and the trap in it.** Nothing before this release recorded a version, so
/// the *absence* of one cannot mean "new install" — it means "old install". What tells
/// them apart is the tour's own flag: someone who has seen the tour has used the app
/// before, whatever the version file says.
///
///     tour not seen                 → the tour, which now covers workspaces
///     tour seen, last run < 0.1.46  → this dialog, once
///     tour seen, no version at all  → this dialog, once (an older install)
///
/// `UserDefaults` and not the support directory: this is news about the *app*, and it
/// should not be repeated by every workspace on the machine. Which is also why the
/// caller gates it on being in the default workspace — a workspace created after the
/// upgrade has never known a GraphCode without them.
enum WorkspaceNews {
  static let lastRunVersionKey = "lastRunVersion"
  static let hasSeenOnboardingKey = "hasSeenOnboarding"

  /// The releases page, not a constructed tag URL: beta tags carry no `v` prefix and
  /// stable ones do, so assembling one by hand is a 404 waiting to happen.
  static let releasesURL = URL(string: "https://github.com/scgopi/GraphCode/releases")!

  /// The release that introduced workspaces. Compared on the release triple *alone*:
  /// they shipped in 0.1.46-beta1, and `AppVersion` sorts every prerelease before its
  /// release — so asking whether a version is `< 0.1.46` calls each of that release's
  /// own betas "before workspaces" and announces the news to someone who has been using
  /// them for a week.
  static let introducedIn = "0.1.46"

  /// `0.1.46` as its triple. `AppVersion` parses from a string and has no memberwise
  /// initializer, so the comparison below works on the numbers rather than rebuilding a
  /// version with its prerelease stripped.
  static let introducedRelease = [0, 1, 46]

  /// Whether a release triple comes before another, padding the shorter with zeros so
  /// `0.1` and `0.1.0` compare equal.
  static func precedes(_ release: [Int], _ other: [Int]) -> Bool {
    for index in 0..<max(release.count, other.count) {
      let left = index < release.count ? release[index] : 0
      let right = index < other.count ? other[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  static func shouldAnnounce(
    currentVersion: String,
    lastRunVersion: String?,
    hasSeenOnboarding: Bool
  ) -> Bool {
    // A fresh install learns it from the tour; announcing as well would be the same
    // lesson twice in one sitting.
    guard hasSeenOnboarding else { return false }
    guard let current = AppVersion(currentVersion),
      !precedes(current.release, introducedRelease)
    else { return false }
    // No recorded version means an install from before this key existed — which is
    // exactly the audience for the news.
    guard let lastRunVersion, let last = AppVersion(lastRunVersion) else { return true }
    return precedes(last.release, introducedRelease)
  }

  /// Reads the two defaults, answers, and records this version either way — so the
  /// question is asked once per machine however it is answered.
  static func announceIfNeeded(
    currentVersion: String, defaults: UserDefaults = .standard
  ) -> Bool {
    let announce = shouldAnnounce(
      currentVersion: currentVersion,
      lastRunVersion: defaults.string(forKey: lastRunVersionKey),
      hasSeenOnboarding: defaults.bool(forKey: hasSeenOnboardingKey))
    defaults.set(currentVersion, forKey: lastRunVersionKey)
    return announce
  }
}
