import Foundation

/// Reads/writes a loop's terminal workspace layout — one JSON file per node, under
/// `<baseDirectory>/terminal-layouts/`. Same shape as `ProjectPersistence`: a plain
/// `Sendable` struct, not an actor, since this is small local file I/O and every call
/// site is already on whatever isolation it needs to be on.
///
/// Deliberately app-side state, not `graphcoded`'s — which tabs/splits a loop's
/// terminal workspace has is a UI concern the daemon has no reason to know about,
/// unlike the graph itself.
public struct TerminalLayoutStore: Sendable {
  private let directory: URL

  public init(baseDirectory: URL) {
    directory = baseDirectory.appendingPathComponent("terminal-layouts", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func load(forNode nodeID: UUID) -> TerminalLayout? {
    guard let data = try? Data(contentsOf: fileURL(forNode: nodeID)) else { return nil }
    return try? JSONDecoder().decode(TerminalLayout.self, from: data)
  }

  public func save(_ layout: TerminalLayout, forNode nodeID: UUID) {
    guard let data = try? JSONEncoder().encode(layout) else { return }
    try? data.write(to: fileURL(forNode: nodeID), options: .atomic)
  }

  private func fileURL(forNode nodeID: UUID) -> URL {
    directory.appendingPathComponent("\(nodeID.uuidString).json")
  }
}
