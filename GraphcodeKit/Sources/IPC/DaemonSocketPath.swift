import Foundation

/// The one Unix domain socket path both `graphcoded` (server) and `graphcode`/the
/// `graphcode` CLI (clients) must agree on. Centralized here instead of duplicated —
/// Phase 0 had `graphcoded/Sources/main.swift` compute this inline, which was fine
/// when nothing else needed to agree with it.
///
/// Kept short on purpose: `sockaddr_un.sun_path` is a hard 104 bytes on Darwin, and this
/// path plus the user's home directory has to fit in it. See `SupportDirectory`.
public enum DaemonSocketPath {
  public static var url: URL {
    SupportDirectory.url.appendingPathComponent("graphcoded.sock")
  }
}
