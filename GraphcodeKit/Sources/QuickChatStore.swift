import Foundation

/// An ad-hoc backend session with no loop semantics: no goal, no trigger, no place in
/// any graph — just a conversation. Deliberately app-local rather than daemon-owned:
/// the daemon's whole job is graphs, hand-offs, and keeping *unattended* sessions
/// alive, and a chat is attended by definition. What keeps a chat's scrollback across
/// app restarts is its `zmx` session, exactly as for a loop — the id here is the
/// session identity (`SurfaceRef(id:).zmxSessionName`), so reopening a chat joins the
/// same live session.
public struct QuickChat: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  /// Fixed at creation from the Settings default, not re-read per open: a chat that
  /// silently switched backends mid-history would join a session whose scrollback came
  /// from a different agent.
  public var backend: CLISessionBackendKind
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    title: String,
    backend: CLISessionBackendKind = .claudeCode,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.title = title
    self.backend = backend
    self.createdAt = createdAt
  }
}

/// Reads/writes the quick-chat list — one JSON file under `<baseDirectory>`. Same shape
/// as `TerminalLayoutStore` and for the same reason: small local file I/O, app-side
/// state the daemon has no reason to know about.
public struct QuickChatStore: Sendable {
  private let fileURL: URL

  public init(baseDirectory: URL) {
    try? FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    fileURL = baseDirectory.appendingPathComponent("quick-chats.json")
  }

  public func load() -> [QuickChat] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([QuickChat].self, from: data)) ?? []
  }

  public func save(_ chats: [QuickChat]) {
    guard let data = try? JSONEncoder().encode(chats) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
