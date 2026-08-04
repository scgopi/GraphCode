import Dependencies
import Foundation
import GraphcodeKit

/// Validates a remote repository connection before it is saved — reachability, the
/// path being a git repository, and the session stack (`zmx`) being installed there.
/// Run up front, in the form, because every one of these failures is otherwise
/// discovered as a loop that silently does nothing: the connection that passes is one
/// whose sessions can actually start.
struct RemoteRepositoryClient: Sendable {
  /// `nil` when the connection is usable; otherwise the reason it isn't, worded for the
  /// sheet's footer.
  var validate: @Sendable (RemoteProjectLocation) async -> String?
}

extension RemoteRepositoryClient: DependencyKey {
  static let liveValue = RemoteRepositoryClient { location in
    RemoteProjectLocation.prepareControlSocketDirectory()
    let quoted = RemoteProjectLocation.shellQuoted
    // Ordered so the first failure names the actual problem: an unreachable host would
    // otherwise read as "not a repository", which sends someone debugging the wrong
    // thing. BatchMode in `sshInvocation` means a password-only host fails here, fast —
    // key auth is a requirement, not a preference, since nothing later has a tty either.
    let checks: [(command: String, failure: String)] = [
      (
        "true",
        "Can't reach \(location.sshDestination) — check the host, and that key "
          + "authentication works (`ssh \(location.sshDestination)` from a terminal)."
      ),
      (
        "test -d \(quoted(location.remotePath))",
        "\(location.remotePath) doesn't exist on \(location.host)."
      ),
      (
        "git -C \(quoted(location.remotePath)) rev-parse --is-inside-work-tree",
        "\(location.remotePath) isn't a git repository."
      ),
      (
        location.remoteLoginShellCommand("command -v zmx"),
        "zmx isn't installed on \(location.host) — sessions live in it. "
          + "Install it there and try again."
      ),
    ]
    for check in checks {
      let invocation = location.sshInvocation(remoteCommand: check.command)
      guard await succeeds(invocation) else { return check.failure }
    }
    return nil
  }

  /// Form tests have no network and should not discover that by hanging.
  static let testValue = RemoteRepositoryClient { _ in nil }

  private static func succeeds(_ invocation: [String]) async -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation[0])
    process.arguments = Array(invocation.dropFirst())
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return false
    }
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { process in
        continuation.resume(returning: process.terminationStatus == 0)
      }
    }
  }
}

extension DependencyValues {
  var remoteRepositoryClient: RemoteRepositoryClient {
    get { self[RemoteRepositoryClient.self] }
    set { self[RemoteRepositoryClient.self] = newValue }
  }
}
