import Dependencies
import Foundation

/// Asks GitHub for the newest stable release, and answers what this build is. Both live
/// here rather than in the reducer so a test can hand the check any release and any
/// installed version without a network or a real bundle.
struct UpdateClient: Sendable {
  var latestRelease: @Sendable () async throws -> UpdateRelease
  var currentVersion: @Sendable () -> String
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
      // what the README's download link and the stable cask install — a beta user is
      // offered the stable line, never a newer beta.
      guard
        let url = URL(string: "https://api.github.com/repos/scgopi/GraphCode/releases/latest")
      else { throw UpdateCheckFailure.requestFailed(status: 0) }
      var request = URLRequest(url: url)
      request.timeoutInterval = 15
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw UpdateCheckFailure.requestFailed(status: http.statusCode)
      }
      return try JSONDecoder().decode(UpdateRelease.self, from: data)
    },
    currentVersion: {
      Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    })

  /// Tests have no network and should not discover that by hanging — a test that wants
  /// a particular release overrides `latestRelease` with a fixture.
  static let testValue = UpdateClient(
    latestRelease: { throw UpdateCheckFailure.requestFailed(status: 0) },
    currentVersion: { "0.0.0" })
}

extension DependencyValues {
  var updateClient: UpdateClient {
    get { self[UpdateClient.self] }
    set { self[UpdateClient.self] = newValue }
  }
}
