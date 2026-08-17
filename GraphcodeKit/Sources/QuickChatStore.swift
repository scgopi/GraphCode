import Foundation

/// An ad-hoc backend session with no loop semantics: no goal, no trigger, no place in
/// any graph — just a conversation. The daemon owns the record and broadcasts mutations;
/// the app still owns the attended terminal surface and attaches to the same zmx session.
public struct QuickChat: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  /// Fixed at creation from the Settings default, not re-read per open: a chat that
  /// silently switched backends mid-history would join a session whose scrollback came
  /// from a different agent.
  public var backend: CLISessionBackendKind
  public var createdAt: Date
  public var activity: QuickChatActivity?

  public init(
    id: UUID = UUID(),
    title: String,
    backend: CLISessionBackendKind = .claudeCode,
    createdAt: Date = Date(),
    activity: QuickChatActivity? = nil
  ) {
    self.id = id
    self.title = title
    self.backend = backend
    self.createdAt = createdAt
    self.activity = activity
  }
}

public struct QuickChatActivity: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var text: String?
  public var presence: PresenceReading?

  public init(sequence: UInt64, text: String? = nil, presence: PresenceReading? = nil) {
    self.sequence = sequence
    self.text = text
    self.presence = presence
  }
}

/// Reads/writes the quick-chat list — one JSON file under `<baseDirectory>`. Same shape
/// as `TerminalLayoutStore` and for the same reason: small local file I/O, app-side
/// state the daemon has no reason to know about.
public enum QuickChatStoreError: Error, Equatable, Sendable {
  case encodingFailed
  case persistenceFailed
  case corruptOrUnreadable
}

public enum QuickChatStoreLoad: Equatable, Sendable {
  case missing
  case loaded([QuickChat])
}

public struct QuickChatStore: Sendable {
  private let fileURL: URL

  public init(baseDirectory: URL) {
    try? FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    fileURL = baseDirectory.appendingPathComponent("quick-chats.json")
  }

  public func load() -> [QuickChat] {
    guard case .loaded(let chats) = (try? loadResult()) ?? .missing else { return [] }
    return chats
  }

  public func loadResult() throws -> QuickChatStoreLoad {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
    do {
      return .loaded(try JSONDecoder().decode([QuickChat].self, from: Data(contentsOf: fileURL)))
    } catch {
      throw QuickChatStoreError.corruptOrUnreadable
    }
  }

  public func save(_ chats: [QuickChat]) throws {
    guard let data = try? JSONEncoder().encode(chats) else {
      throw QuickChatStoreError.encodingFailed
    }
    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      throw QuickChatStoreError.persistenceFailed
    }
  }

  public func create(_ chat: QuickChat) throws {
    var chats = try loadedChats().filter { $0.id != chat.id }
    chats.append(chat)
    try save(chats.sorted { $0.createdAt < $1.createdAt })
  }

  public func chat(id: UUID) -> QuickChat? {
    load().first { $0.id == id }
  }

  public func rename(id: UUID, title: String) throws -> QuickChat? {
    var chats = try loadedChats()
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
    chats[index].title = title
    try save(chats)
    return chats[index]
  }

  public func delete(id: UUID) throws -> QuickChat? {
    var chats = try loadedChats()
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
    let removed = chats.remove(at: index)
    try save(chats)
    return removed
  }

  public func updateActivity(id: UUID, activity: QuickChatActivity) throws -> QuickChat? {
    var chats = try loadedChats()
    guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
    chats[index].activity = activity
    try save(chats)
    return chats[index]
  }

  private func loadedChats() throws -> [QuickChat] {
    switch try loadResult() {
    case .missing: return []
    case .loaded(let chats): return chats
    }
  }
}
