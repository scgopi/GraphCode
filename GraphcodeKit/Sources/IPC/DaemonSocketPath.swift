import Foundation

/// The one Unix domain socket path both `graphcoded` (server) and `graphcode`/the
/// `graphcode` CLI (clients) must agree on. Centralized here instead of duplicated —
/// Phase 0 had `graphcoded/Sources/main.swift` compute this inline, which was fine
/// when nothing else needed to agree with it.
public enum DaemonSocketPath {
  public static var url: URL {
    let supportDirectory = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("graphcode", isDirectory: true)
    return supportDirectory.appendingPathComponent("graphcoded.sock")
  }
}
