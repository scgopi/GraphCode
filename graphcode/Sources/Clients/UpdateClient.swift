import Dependencies
import Foundation

/// Asks GitHub what releases exist, and answers what this build is and which channel it
/// follows. All of it lives here rather than in the reducer so a test can hand the check
/// any release, any installed version, and any channel without a network or a real
/// bundle or defaults.
struct UpdateClient: Sendable {
  var latestRelease: @Sendable () async throws -> UpdateRelease
  var allReleases: @Sendable () async throws -> [UpdateRelease]
  var currentVersion: @Sendable () -> String
  /// The `updateChannel` default, verbatim — "beta" opts a stable install into
  /// prereleases, "stable" pins a beta build to stables. Interpreting it (including
  /// ignoring garbage) is `UpdateChannel.channel(for:override:)`'s job.
  var channelOverride: @Sendable () -> String?
}

enum UpdateCheckFailure: Error, LocalizedError, Equatable {
  case requestFailed(status: Int)

  var errorDescription: String? {
    switch self {
    case .requestFailed(let status):
      return "GitHub answered with status \(status)."
    }
  }
}

extension UpdateClient: DependencyKey {
  static let liveValue = UpdateClient(
    latestRelease: {
      // `releases/latest` excludes drafts and prereleases by definition, which matches
      // what the README's download link and the stable cask install — the stable
      // channel's whole answer in one request.
      try await fetch("releases/latest")
    },
    allReleases: {
      // The list includes prereleases; drafts only appear to authenticated callers,
      // which this request never is. One page is a year of this project's history.
      try await fetch("releases?per_page=30")
    },
    currentVersion: {
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    },
    channelOverride: {
      UserDefaults.standard.string(forKey: "updateChannel")
    })

  private static func fetch<Value: Decodable>(_ path: String) async throws -> Value {
    guard let url = URL(string: "https://api.github.com/repos/scgopi/GraphCode/\(path)")
    else { throw UpdateCheckFailure.requestFailed(status: 0) }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      throw UpdateCheckFailure.requestFailed(status: http.statusCode)
    }
    return try JSONDecoder().decode(Value.self, from: data)
  }

  /// Tests have no network and should not discover that by hanging — a test that wants
  /// a particular release overrides `latestRelease` or `allReleases` with a fixture.
  static let testValue = UpdateClient(
    latestRelease: { throw UpdateCheckFailure.requestFailed(status: 0) },
    allReleases: { throw UpdateCheckFailure.requestFailed(status: 0) },
    currentVersion: { "0.0.0" },
    channelOverride: { nil })
}

extension DependencyValues {
  var updateClient: UpdateClient {
    get { self[UpdateClient.self] }
    set { self[UpdateClient.self] = newValue }
  }
}
