import Foundation

/// The one Unix domain socket path both `graphcoded` (server) and `graphcode`/the
/// `graphcode` CLI (clients) must agree on. Centralized here instead of duplicated —
/// Phase 0 had `graphcoded/Sources/main.swift` compute this inline, which was fine
/// when nothing else needed to agree with it.
///
/// Kept short on purpose: `sockaddr_un.sun_path` is a hard 104 bytes on Darwin, and this
/// path plus the user's home directory has to fit in it. See `SupportDirectory`.
public enum DaemonSocketPath {
  /// Points clients (and a daemon binding it) at a socket somewhere other than the
  /// support directory's — the escape hatch a forwarded or relocated socket needs.
  /// `GRAPHCODE_SUPPORT_DIR` already moves the whole directory; this moves just the
  /// socket, which is what `ssh -R` hands you.
  public static let environmentKey = "GRAPHCODE_SOCKET"

  public static var url: URL {
    url(environment: ProcessInfo.processInfo.environment)
  }

  /// The transport endpoint shared by the daemon and its local clients.
  public static var endpoint: DaemonEndpoint {
    #if os(Windows)
      return .namedPipe((try? WindowsNamedPipeEndpoint.name()) ?? "")
    #else
      return .unixSocket(url)
    #endif
  }

  /// The concrete Windows pipe name. Exposed for launchers and tests so they
  /// never duplicate the SID/support-directory naming policy.
  #if os(Windows)
    public static var pipeName: String? {
      try? WindowsNamedPipeEndpoint.name()
    }
  #endif

  /// Injected environment, so tests can state an override without mutating the
  /// process's — the `SupportDirectory.prepare(destination:legacy:)` lesson.
  static func url(environment: [String: String]) -> URL {
    if let override = environment[environmentKey],
      !override.trimmingCharacters(in: .whitespaces).isEmpty
    {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return SupportDirectory.url.appendingPathComponent("graphcoded.sock")
  }
}
