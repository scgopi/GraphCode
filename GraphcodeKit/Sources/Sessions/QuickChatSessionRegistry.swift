import Foundation

/// Durable ownership index for daemon-owned Quick Chat zmx sessions. It is
/// intentionally separate from graph loop session IDs so orphan cleanup can never
/// terminate a normal graph session.
public enum QuickChatSessionRegistry {
  private static var directory: URL {
    SupportDirectory.url.appendingPathComponent("quick-chat-sessions", isDirectory: true)
  }

  public static func markLive(_ id: UUID) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data(id.uuidString.utf8).write(
      to: directory.appendingPathComponent("\(id.uuidString).id"), options: .atomic)
  }

  public static func remove(_ id: UUID) {
    try? FileManager.default.removeItem(
      at: directory.appendingPathComponent("\(id.uuidString).id"))
  }

  public static func ids() -> [UUID] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil) else { return [] }
    return files.compactMap {
      UUID(uuidString: $0.deletingPathExtension().lastPathComponent)
    }
  }
}
