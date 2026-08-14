import Foundation

/// Resolves the platform's OpenSSH client without baking a Darwin path into Windows
/// production session commands.
public enum SSHExecutableResolver {
  public static func executableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    #if os(Windows)
      let candidates =
        environment["PATH"]?
        .split(separator: ";")
        .map(String.init)
        .map { URL(fileURLWithPath: $0).appendingPathComponent("ssh.exe") }
        ?? []
      let systemRoot = environment["SystemRoot"] ?? environment["WINDIR"] ?? "C:\\Windows"
      let system = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32/OpenSSH/ssh.exe")
      return (candidates + [system]).first {
        FileManager.default.isExecutableFile(atPath: $0.path)
      }
    #else
      return URL(fileURLWithPath: "/usr/bin/ssh")
    #endif
  }
}
