import Foundation

/// Where to find the `zmx` binary — see docs/07-roadmap.md's zmx integration.
/// `make install-zmx` copies the build output here, mirroring how `graphcoded` itself
/// lives under `~/.graphcode`: a fixed, known path is simpler than requiring `zmx` on the
/// app's (often minimal, launchd-provided) `PATH`.
public enum ZmxLocator {
  public static var binaryURL: URL {
    #if os(Windows)
      resolve(
        candidates(
          executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent(),
          supportBinDirectory: SupportDirectory.binDirectory,
          executableName: "zmx.exe"),
        isExecutable: FileManager.default.isExecutableFile(atPath:))
    #else
      SupportDirectory.binDirectory.appendingPathComponent("zmx")
    #endif
  }

  public static var isInstalled: Bool {
    FileManager.default.isExecutableFile(atPath: binaryURL.path)
  }

  /// The places `zmx` may live, most preferred first; the last is the support directory's
  /// `bin`, which is also what is reported when none of them exists. The Windows package
  /// installs `zmx.exe` beside `graphcoded.exe` and never copies it into the support
  /// directory, so the running executable's own directory comes first.
  static func candidates(
    executableDirectory: URL?, supportBinDirectory: URL, executableName: String
  ) -> [URL] {
    let supportBinary = supportBinDirectory.appendingPathComponent(executableName)
    guard let executableDirectory else { return [supportBinary] }
    return [executableDirectory.appendingPathComponent(executableName), supportBinary]
  }

  static func resolve(_ candidates: [URL], isExecutable: (String) -> Bool) -> URL {
    candidates.first { isExecutable($0.path) } ?? candidates[candidates.count - 1]
  }
}
