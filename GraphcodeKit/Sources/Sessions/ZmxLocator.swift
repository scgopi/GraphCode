import Foundation

/// Where to find the `zmx` binary — see docs/07-roadmap.md's zmx integration.
/// `make install-zmx` copies the build output here, mirroring how `graphcoded` itself
/// lives under Application Support: a fixed, known path is simpler than requiring
/// `zmx` on the app's (often minimal, launchd-provided) `PATH`.
public enum ZmxLocator {
  public static var binaryURL: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("graphcode", isDirectory: true)
      .appendingPathComponent("bin", isDirectory: true)
      .appendingPathComponent("zmx")
  }

  public static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: binaryURL.path)
  }
}
