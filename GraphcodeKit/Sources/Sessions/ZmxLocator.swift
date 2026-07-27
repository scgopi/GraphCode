import Foundation

/// Where to find the `zmx` binary — see docs/07-roadmap.md's zmx integration.
/// `make install-zmx` copies the build output here, mirroring how `graphcoded` itself
/// lives under `~/.graphcode`: a fixed, known path is simpler than requiring `zmx` on the
/// app's (often minimal, launchd-provided) `PATH`.
public enum ZmxLocator {
  public static var binaryURL: URL {
    SupportDirectory.binDirectory.appendingPathComponent("zmx")
  }

  public static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: binaryURL.path)
  }
}
