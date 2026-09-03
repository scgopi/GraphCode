import Foundation
import GraphcodeKit
import OSLog

/// One line per step of a self-update, written to `~/.graphcode/update.log` on the machine
/// that ran it.
///
/// An install that wedges leaves no other trace: the flow reports progress through the
/// store, so a step that never returns shows as a dialog stuck on "Installing…" and
/// nothing else — no error, no console output, nothing to send. The steps are a download,
/// three subprocesses and two renames, and which of them stopped is the whole diagnosis.
///
/// Also mirrored to `os.Logger` so `log stream --predicate 'subsystem == "dev.graphcode.app"'`
/// shows it live while reproducing.
enum UpdateLog {
  static let maxBytes = 262_144
  static let keptLines = 2000

  private static let logger = Logger(subsystem: "dev.graphcode.app", category: "update")

  /// Best-effort by the same rule as `DialLog`: failing to log must never fail an install.
  static func record(_ message: String) {
    logger.info("\(message, privacy: .public)")
    let fileManager = FileManager.default
    let directory = SupportDirectory.url
    let log = directory.appendingPathComponent("update.log")
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    let size = (try? fileManager.attributesOfItem(atPath: log.path))?[.size] as? Int ?? 0
    if size > maxBytes, let contents = try? String(contentsOf: log, encoding: .utf8) {
      let kept = contents.split(separator: "\n").suffix(keptLines).joined(separator: "\n")
      try? (kept + "\n" + line).write(to: log, atomically: true, encoding: .utf8)
      return
    }
    if let handle = try? FileHandle(forWritingTo: log) {
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
      try? handle.close()
    } else {
      try? Data(line.utf8).write(to: log)
    }
  }

  /// Runs `body`, logging the step's start and how it ended — including the elapsed time,
  /// which is what separates "slow" from "wedged" when reading the log afterwards.
  @discardableResult
  static func step<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
    record("\(name): started")
    let began = Date()
    do {
      let value = try await body()
      record("\(name): ok in \(elapsed(since: began))")
      return value
    } catch {
      record("\(name): FAILED in \(elapsed(since: began)) — \(error)")
      throw error
    }
  }

  static func elapsed(since date: Date) -> String {
    String(format: "%.1fs", Date().timeIntervalSince(date))
  }
}
