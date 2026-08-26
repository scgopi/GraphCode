import Foundation

#if os(Windows)
  import WinSDK
#endif

public enum PlatformPathError: Error, Equatable, LocalizedError, Sendable {
  case emptyPath
  case notAbsolute(String)
  case remotePath(String)
  case rootPath(String)

  public var errorDescription: String? {
    switch self {
    case .emptyPath:
      return "The project path is empty."
    case .notAbsolute(let path):
      return "The project path is not absolute: \(path)"
    case .remotePath(let path):
      return "The project path is remote, not local: \(path)"
    case .rootPath(let path):
      return "The filesystem root is not a project: \(path)"
    }
  }
}
public struct WindowsPlatformPaths: PlatformPaths {
  public let supportDirectory: URL
  public let binDirectory: URL
  public let hooksDirectory: URL
  public let sessionsDirectory: URL

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    let root = SupportDirectory.url(environment: environment, homeDirectory: homeDirectory)
    supportDirectory = root
    binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    hooksDirectory = root.appendingPathComponent("hooks", isDirectory: true)
    sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
  }

  public func canonicalProjectPath(_ path: String) throws -> String {
    try PlatformPathAlgorithms.canonicalProjectPath(path, windows: true)
  }

  public func persistenceKey(forProjectPath path: String) -> String {
    let canonical = (try? canonicalProjectPath(path)) ?? path
    return PlatformPersistenceKey.make(for: canonical)
  }
}
public struct DarwinPlatformPaths: PlatformPaths {
  public let supportDirectory: URL
  public let binDirectory: URL
  public let hooksDirectory: URL
  public let sessionsDirectory: URL

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) {
    let root = SupportDirectory.url(environment: environment, homeDirectory: homeDirectory)
    supportDirectory = root
    binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    hooksDirectory = root.appendingPathComponent("hooks", isDirectory: true)
    sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
  }

  public func canonicalProjectPath(_ path: String) throws -> String {
    try PlatformPathAlgorithms.canonicalProjectPath(path, windows: false)
  }

  public func persistenceKey(forProjectPath path: String) -> String {
    let canonical = (try? canonicalProjectPath(path)) ?? path
    return PlatformPersistenceKey.make(for: canonical)
  }
}

#if os(Windows)
  public typealias DefaultPlatformPaths = WindowsPlatformPaths
#else
  public typealias DefaultPlatformPaths = DarwinPlatformPaths
#endif

public enum CurrentPlatformPaths {
  public static var value: any PlatformPaths {
    #if os(Windows)
      WindowsPlatformPaths()
    #else
      DarwinPlatformPaths()
    #endif
  }
}
private enum PlatformPathAlgorithms {
  static func canonicalProjectPath(_ path: String, windows: Bool) throws -> String {
    guard !path.isEmpty else { throw PlatformPathError.emptyPath }
    guard !looksLikeRemotePath(path) else { throw PlatformPathError.remotePath(path) }
    guard windows ? isWindowsAbsolute(path) : path.hasPrefix("/") else {
      throw PlatformPathError.notAbsolute(path)
    }
    guard !isRootPath(path, windows: windows) else {
      throw PlatformPathError.rootPath(path)
    }
    // Lexically, before any symlink resolution. `standardizedFileURL` resolves `/tmp`
    // first, so `/tmp/..` lands on `/private` — a real directory that is not the root
    // and would therefore be accepted, when what was named reduces to `/`.
    if !windows, RemoteProjectLocation.normalizedPath(path) == "/" {
      throw PlatformPathError.rootPath(path)
    }

    let canonical: String
    if windows {
      let normalized = canonicalWindowsPath(path)
      guard !isRootPath(normalized, windows: true) else {
        throw PlatformPathError.rootPath(path)
      }
      let resolved = canonicalWindowsPath(resolveWindowsFinalPath(normalized))
      guard !isRootPath(resolved, windows: true) else {
        throw PlatformPathError.rootPath(path)
      }
      let urlPath = URL(fileURLWithPath: resolved).standardizedFileURL.path
      canonical =
        resolved.hasPrefix("\\\\") && !urlPath.hasPrefix("//")
        ? "/" + urlPath
        : urlPath
    } else {
      canonical =
        URL(fileURLWithPath: path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
    }
    guard !isRootPath(canonical, windows: windows) else {
      throw PlatformPathError.rootPath(path)
    }
    return canonical
  }

  private static func looksLikeRemotePath(_ path: String) -> Bool {
    path.range(
      of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
      options: .regularExpression) != nil
  }

  private static func isWindowsAbsolute(_ path: String) -> Bool {
    if path.hasPrefix("\\\\") || path.hasPrefix("//") {
      return true
    }
    guard path.count >= 3 else { return false }
    let characters = Array(path)
    return characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/")
  }

  private static func canonicalWindowsPath(_ path: String) -> String {
    let normalized = normalizeWindowsFinalPath(path)
    if normalized.hasPrefix("\\\\") {
      let components = normalized.split(separator: "\\", omittingEmptySubsequences: true)
      guard components.count >= 2 else { return normalized }
      let root = components.prefix(2).map(String.init)
      let tail = collapseWindowsComponents(components.dropFirst(2))
      return "\\\\" + (root + tail).joined(separator: "\\")
    }

    let drive = String(normalized.prefix(2))
    let tail = normalized.dropFirst(2)
    let components = tail.split(separator: "\\", omittingEmptySubsequences: true)
    let collapsed = collapseWindowsComponents(components)
    return drive + "\\" + collapsed.joined(separator: "\\")
  }

  private static func resolveWindowsFinalPath(_ path: String) -> String {
    #if os(Windows)
      var widePath = Array(path.utf16)
      widePath.append(0)
      let handle = widePath.withUnsafeBufferPointer {
        CreateFileW(
          $0.baseAddress,
          DWORD(FILE_READ_ATTRIBUTES),
          DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE) | DWORD(FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_BACKUP_SEMANTICS),
          nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        return path
      }
      defer { _ = CloseHandle(handle) }

      var buffer = [WCHAR](repeating: 0, count: 260)
      while true {
        let length = buffer.withUnsafeMutableBufferPointer {
          GetFinalPathNameByHandleW(
            handle,
            $0.baseAddress,
            DWORD($0.count),
            DWORD(VOLUME_NAME_DOS))
        }
        guard length > 0 else { return path }
        if Int(length) < buffer.count {
          let resolved = String(
            decoding: buffer.prefix(Int(length)),
            as: UTF16.self)
          return normalizeWindowsFinalPath(resolved)
        }
        buffer = [WCHAR](repeating: 0, count: Int(length) + 1)
      }
    #else
      return path
    #endif
  }

  private static func normalizeWindowsFinalPath(_ path: String) -> String {
    let normalized = path.replacingOccurrences(of: "/", with: "\\")
    let uncPrefix = "\\\\?\\UNC\\"
    if normalized.range(of: uncPrefix, options: [.caseInsensitive, .anchored]) != nil {
      return "\\\\" + String(normalized.dropFirst(uncPrefix.count))
    }
    let devicePrefix = "\\\\?\\"
    if normalized.range(of: devicePrefix, options: [.caseInsensitive, .anchored]) != nil {
      return String(normalized.dropFirst(devicePrefix.count))
    }
    return normalized
  }

  private static func collapseWindowsComponents(
    _ components: some Collection<Substring>
  ) -> [String] {
    var collapsed: [String] = []
    for component in components {
      switch component {
      case ".":
        continue
      case "..":
        if !collapsed.isEmpty { collapsed.removeLast() }
      default:
        collapsed.append(String(component))
      }
    }
    return collapsed
  }

  private static func isRootPath(_ path: String, windows: Bool) -> Bool {
    if !windows {
      let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
      return normalized == "/"
    }

    let normalized = canonicalWindowsPath(path)
    if normalized.range(
      of: #"^[A-Za-z]:\\*$"#,
      options: .regularExpression) != nil
    {
      return true
    }
    if normalized == "\\" || normalized == "\\\\" {
      return true
    }

    let components = normalized.split(separator: "\\", omittingEmptySubsequences: true)
    return normalized.hasPrefix("\\\\") && components.count <= 2
  }
}
private enum PlatformPersistenceKey {
  static func make(for path: String) -> String {
    "v1-" + GraphcodeSHA256.hex(Data(path.utf8))
  }
}
/// Small dependency-free SHA-256 used for stable, privacy-preserving path
/// identities on every supported platform.
internal enum GraphcodeSHA256 {
  private static let initial: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]

  private static let constants: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1,
    0x923f_82a4, 0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
    0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786,
    0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147,
    0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
    0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
    0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a,
    0x5b9c_ca4f, 0x682e_6ff3, 0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
    0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
  ]

  static func hex(_ data: Data) -> String {
    var message = Array(data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 {
      message.append(0)
    }
    message.append(contentsOf: [
      UInt8(truncatingIfNeeded: bitLength >> 56),
      UInt8(truncatingIfNeeded: bitLength >> 48),
      UInt8(truncatingIfNeeded: bitLength >> 40),
      UInt8(truncatingIfNeeded: bitLength >> 32),
      UInt8(truncatingIfNeeded: bitLength >> 24),
      UInt8(truncatingIfNeeded: bitLength >> 16),
      UInt8(truncatingIfNeeded: bitLength >> 8),
      UInt8(truncatingIfNeeded: bitLength),
    ])

    var hash = initial
    for chunkStart in stride(from: 0, to: message.count, by: 64) {
      var schedule = [UInt32](repeating: 0, count: 64)
      for index in 0..<16 {
        let offset = chunkStart + index * 4
        schedule[index] =
          UInt32(message[offset]) << 24
          | UInt32(message[offset + 1]) << 16
          | UInt32(message[offset + 2]) << 8
          | UInt32(message[offset + 3])
      }
      for index in 16..<64 {
        let s0 =
          rotateRight(schedule[index - 15], by: 7)
          ^ rotateRight(schedule[index - 15], by: 18)
          ^ (schedule[index - 15] >> 3)
        let s1 =
          rotateRight(schedule[index - 2], by: 17)
          ^ rotateRight(schedule[index - 2], by: 19)
          ^ (schedule[index - 2] >> 10)
        schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
      }

      var working = hash
      for index in 0..<64 {
        let s1 =
          rotateRight(working[4], by: 6)
          ^ rotateRight(working[4], by: 11)
          ^ rotateRight(working[4], by: 25)
        let choice = (working[4] & working[5]) ^ (~working[4] & working[6])
        let temporary1 = working[7] &+ s1 &+ choice &+ constants[index] &+ schedule[index]
        let s0 =
          rotateRight(working[0], by: 2)
          ^ rotateRight(working[0], by: 13)
          ^ rotateRight(working[0], by: 22)
        let majority =
          (working[0] & working[1])
          ^ (working[0] & working[2])
          ^ (working[1] & working[2])
        let temporary2 = s0 &+ majority

        working[7] = working[6]
        working[6] = working[5]
        working[5] = working[4]
        working[4] = working[3] &+ temporary1
        working[3] = working[2]
        working[2] = working[1]
        working[1] = working[0]
        working[0] = temporary1 &+ temporary2
      }
      for index in 0..<8 {
        hash[index] = hash[index] &+ working[index]
      }
    }

    return hash.map { word in
      let hex = String(word, radix: 16)
      return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }.joined()
  }

  private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
  }
}
