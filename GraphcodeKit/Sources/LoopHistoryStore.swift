import Foundation

/// Reads/writes the back/forward stack — one JSON file under `<baseDirectory>`. Same
/// shape as `QuickChatStore` and for the same reason: small local file I/O, app-side
/// state the daemon has no reason to know about.
///
/// Nothing is validated on the way in. Which loops still exist is a question only the
/// live graphs can answer, and at load time none of them have arrived from the daemon
/// yet — a validating load would throw away a perfectly good history every launch.
/// `LoopHistory.back(where:)` steps over what no longer resolves instead.
public struct LoopHistoryStore: Sendable {
  private let fileURL: URL

  public init(baseDirectory: URL) {
    try? FileManager.default.createDirectory(
      at: baseDirectory, withIntermediateDirectories: true)
    fileURL = baseDirectory.appendingPathComponent("loop-history.json")
  }

  public func load() -> LoopHistory {
    guard let data = try? Data(contentsOf: fileURL) else { return LoopHistory() }
    return (try? JSONDecoder().decode(LoopHistory.self, from: data)) ?? LoopHistory()
  }

  public func save(_ history: LoopHistory) {
    guard let data = try? JSONEncoder().encode(history) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
