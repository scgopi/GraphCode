import Foundation

/// The SSH destination components kept separate until argv construction.
/// In particular, an IPv6 host is never confused with a `host:port` authority.
public struct WindowsSSHAuthority: Equatable, Sendable {
  public let user: String?
  public let host: String
  public let port: UInt16?

  public init(user: String? = nil, host: String, port: UInt16? = nil) {
    self.user = user
    if host.first == "[", host.last == "]", host.count >= 2 {
      self.host = String(host.dropFirst().dropLast())
    } else {
      self.host = host
    }
    self.port = port
  }

  public var key: String {
    let userPart = user.map { "\($0)@" } ?? ""
    let hostPart = host.contains(":") ? "[\(host)]" : host
    let portPart = port.map { ":\($0)" } ?? ""
    return "\(userPart)\(hostPart)\(portPart)"
  }

  public var destination: String {
    let userPart = user.map { "\($0)@" } ?? ""
    let hostPart = host.contains(":") ? "[\(host)]" : host
    return "\(userPart)\(hostPart)"
  }

  public init?(authority: String) {
    let pieces = authority.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let user: String?
    let destination: Substring
    if pieces.count == 2 {
      guard !pieces[0].isEmpty else { return nil }
      user = String(pieces[0])
      destination = pieces[1]
    } else {
      user = nil
      destination = pieces[0]
    }
    guard !destination.isEmpty else { return nil }

    if destination.first == "[" {
      guard let closing = destination.firstIndex(of: "]") else { return nil }
      let host = destination[destination.index(after: destination.startIndex)..<closing]
      guard !host.isEmpty else { return nil }
      let suffix = destination[destination.index(after: closing)...]
      if suffix.isEmpty {
        self.init(user: user, host: String(host))
        return
      }
      guard suffix.first == ":", let port = UInt16(suffix.dropFirst()), port > 0 else {
        return nil
      }
      self.init(user: user, host: String(host), port: port)
      return
    }

    let colonCount = destination.filter { $0 == ":" }.count
    if colonCount > 1 {
      self.init(user: user, host: String(destination))
      return
    }
    if let colon = destination.lastIndex(of: ":") {
      let host = destination[..<colon]
      guard !host.isEmpty, let port = UInt16(destination[destination.index(after: colon)...]),
        port > 0
      else { return nil }
      self.init(user: user, host: String(host), port: port)
      return
    }
    self.init(user: user, host: String(destination))
  }
}

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
