import Foundation

/// A version as the app and its release tags write one — `0.1.14`, `v0.1.14`,
/// `0.1.14-beta3`. One parser for both sides of the comparison, because the two
/// spellings genuinely differ: stable tags carry a `v` prefix, beta tags don't
/// (see `TAG_PREFIX` in the Makefile), and the bundle's own
/// `CFBundleShortVersionString` carries neither prefix nor prerelease.
struct AppVersion: Equatable, Comparable, Sendable {
  var release: [Int]
  /// The prerelease's number — `0.1.14-beta3` is `3`. `nil` means a stable version,
  /// which sorts *after* every prerelease of the same release.
  var prerelease: Int?

  init?(_ string: String) {
    var text = Substring(string.trimmingCharacters(in: .whitespaces))
    if text.hasPrefix("v") { text = text.dropFirst() }
    let parts = text.split(separator: "-", maxSplits: 1)
    guard let numeric = parts.first else { return nil }
    let components = numeric.split(separator: ".", omittingEmptySubsequences: false)
    guard !components.isEmpty else { return nil }
    var numbers: [Int] = []
    for component in components {
      guard let number = Int(component) else { return nil }
      numbers.append(number)
    }
    release = numbers
    if parts.count == 2 {
      // "beta3" — the digits order prereleases among themselves; a marker with no
      // number still counts as a prerelease, just the earliest possible one.
      prerelease = Int(parts[1].drop { !$0.isNumber }) ?? 0
    }
  }

  static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    // Padded numeric comparison, not lexicographic — "0.1.9" < "0.1.14" is the case
    // that string comparison gets wrong, and this project has already shipped both.
    for index in 0..<max(lhs.release.count, rhs.release.count) {
      let left = index < lhs.release.count ? lhs.release[index] : 0
      let right = index < rhs.release.count ? rhs.release[index] : 0
      if left != right { return left < right }
    }
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (.some, nil): return true
    case (nil, .some): return false
    case (.some(let left), .some(let right)): return left < right
    }
  }
}

/// The slice of a GitHub release the update check reads —
/// `GET /repos/…/releases/latest`, which is GitHub's own "newest stable": drafts and
/// prereleases never appear in it, matching what the DMG link and the cask ship.
struct UpdateRelease: Equatable, Sendable, Decodable {
  struct Asset: Equatable, Sendable, Decodable {
    var name: String
    var browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }

  var tagName: String
  var htmlURL: URL
  var assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case assets
  }

  /// The DMG this release ships — the exact name `release-dmg` uploads, falling back
  /// to any `.dmg` so a renamed asset degrades to a working download rather than none.
  var dmgDownloadURL: URL? {
    let exact = assets.first { $0.name == "graphcode-macos-arm64.dmg" }
    let anyDMG = assets.first { $0.name.hasSuffix(".dmg") }
    return (exact ?? anyDMG)?.browserDownloadURL
  }

  /// The tag as a human version — `v0.1.14` reads as `0.1.14` everywhere the app says it.
  var displayVersion: String {
    tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
  }
}

/// A newer release the check found, shaped for the alert that offers it.
struct AvailableUpdate: Equatable, Sendable {
  var version: String
  var currentVersion: String
  var downloadURL: URL
  var releaseNotesURL: URL
}

enum AppUpdate {
  /// The whole decision: the update the release represents for someone on `current`,
  /// or `nil` when there's nothing newer. An unparsable version on either side also
  /// answers `nil` — a dev build with no real version should never be nagged, and a
  /// malformed tag is GitHub telling us nothing trustworthy.
  static func available(current: String, release: UpdateRelease) -> AvailableUpdate? {
    guard let installed = AppVersion(current), let latest = AppVersion(release.tagName),
      installed < latest
    else { return nil }
    return AvailableUpdate(
      version: release.displayVersion,
      currentVersion: current,
      downloadURL: release.dmgDownloadURL ?? release.htmlURL,
      releaseNotesURL: release.htmlURL)
  }
}
