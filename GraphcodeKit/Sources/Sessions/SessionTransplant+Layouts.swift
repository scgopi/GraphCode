import Foundation

extension SessionTransplant {
  static func restorePi(
    _ artifact: Artifact, forNodeID nodeID: UUID, projectPath: String
  ) -> String? {
    guard let session = artifact.files["session.jsonl"] else { return nil }
    let freshID = UUID().uuidString.lowercased()
    guard
      let rewritten = rewritingPiSession(
        session, replacing: artifact.sessionID, with: freshID, workingDirectory: projectPath)
    else { return nil }
    let directory =
      piSessionsRoot
      .appendingPathComponent(piSessionSlug(forWorkingDirectory: projectPath))
    guard write(rewritten, to: directory.appendingPathComponent(piSessionFileName(id: freshID)))
    else { return nil }
    SessionIDStore.save(freshID, forNodeID: nodeID)
    return freshID
  }

  // MARK: - Backend layouts

  static var claudeProjectsRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("projects", isDirectory: true)
  }

  /// Where imported Codex rollouts land: a dated directory like the ones `codex`
  /// itself writes, under today's date at import time.
  static var codexImportDirectory: URL {
    let parts = Calendar(identifier: .gregorian)
      .dateComponents([.year, .month, .day], from: Date())
    return CodexSessionLog.sessionsDirectory
      .appendingPathComponent(String(parts.year ?? 1970), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.month ?? 1), isDirectory: true)
      .appendingPathComponent(String(format: "%02d", parts.day ?? 1), isDirectory: true)
  }

  /// Claude Code's directory name for a working directory: the *resolved* path with
  /// every non-alphanumeric character replaced by `-`. Resolution matters — a session
  /// started in `/tmp/x` is recorded under `-private-tmp-x` — and it has to be POSIX
  /// `realpath`, because Foundation's `resolvingSymlinksInPath()` deliberately leaves
  /// `/private` prefixes unresolved and produced the wrong directory for exactly
  /// those paths.
  static func claudeProjectSlug(forWorkingDirectory path: String) -> String {
    let resolved = resolvedWorkingDirectory(path)
    return String(resolved.map { $0.isLetter || $0.isNumber ? $0 : "-" })
  }

  static func findClaudeTranscript(sessionID: String) -> URL? {
    // Found by id across every project directory rather than by reconstructing which
    // directory the session ran in — a loop bound to a worktree recorded its
    // transcript under the worktree's slug, not the project's, and the id is unique
    // either way.
    let fileManager = FileManager.default
    guard
      let projectDirs = try? fileManager.contentsOfDirectory(
        at: claudeProjectsRoot, includingPropertiesForKeys: nil)
    else { return nil }
    for directory in projectDirs {
      let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
      if fileManager.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  static var piSessionsRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".pi", isDirectory: true)
      .appendingPathComponent("agent", isDirectory: true)
      .appendingPathComponent("sessions", isDirectory: true)
  }

  /// pi's directory name for a working directory: `--<path>--`, the leading separator
  /// dropped and every `/`, `\` and `:` replaced by `-`. pi applies it to `process.cwd()`,
  /// which is already resolved, hence `realpath` as for Claude's slug.
  static func piSessionSlug(forWorkingDirectory path: String) -> String {
    let resolved = resolvedWorkingDirectory(path)
    let trimmed = resolved.hasPrefix("/") ? String(resolved.dropFirst()) : resolved
    return "--" + String(trimmed.map { "/\\:".contains($0) ? "-" : $0 }) + "--"
  }

  private static func resolvedWorkingDirectory(_ path: String) -> String {
    #if os(Windows)
      return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    #else
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      return path.withCString { realpath($0, &buffer).map { String(cString: $0) } } ?? path
    #endif
  }

  /// `<timestamp>_<id>.jsonl`, the timestamp in pi's own shape: ISO 8601 with `:` and `.`
  /// replaced by `-`.
  static func piSessionFileName(id: String, at date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: date)
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    return "\(stamp)_\(id).jsonl"
  }

  /// The session with every occurrence of its id replaced and the header line's `id` and
  /// `cwd` set to the new identity and working directory. Nil when the first line is not a
  /// pi session header — a file pi itself would refuse to list.
  static func rewritingPiSession(
    _ data: Data, replacing oldID: String, with freshID: String, workingDirectory: String
  ) -> Data? {
    let body = rewriting(data, replacing: oldID, with: freshID)
    let newline = body.firstIndex(of: UInt8(ascii: "\n")) ?? body.endIndex
    guard
      var header = (try? JSONSerialization.jsonObject(with: Data(body[..<newline])))
        as? [String: Any],
      header["type"] as? String == "session"
    else { return nil }
    header["id"] = freshID
    header["cwd"] = workingDirectory
    guard
      let line = try? JSONSerialization.data(
        withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return line + body[newline...]
  }

  /// Found by id across every slug directory, like `findClaudeTranscript`: a
  /// worktree-bound loop recorded its session under the worktree's slug.
  static func findPiSession(sessionID: String) -> URL? {
    let fileManager = FileManager.default
    guard
      let slugDirs = try? fileManager.contentsOfDirectory(
        at: piSessionsRoot, includingPropertiesForKeys: nil)
    else { return nil }
    let suffix = "_\(sessionID).jsonl"
    for directory in slugDirs {
      guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
        continue
      }
      if let name = names.first(where: { $0.hasSuffix(suffix) }) {
        return directory.appendingPathComponent(name)
      }
    }
    return nil
  }

  /// The `<uuid>` inside a `rollout-<timestamp>-<uuid>.jsonl` filename.
  static func rolloutUUID(in filename: String) -> String? {
    let stem = filename.hasSuffix(".jsonl") ? String(filename.dropLast(6)) : filename
    let tail = stem.split(separator: "-").suffix(5).joined(separator: "-")
    return UUID(uuidString: tail) != nil ? tail : nil
  }

  // MARK: - File plumbing

  static func filesUnder(_ root: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])
    else { return files }
    // Resolved on both sides before the prefix strip, or a symlinked component
    // (`/var` → `/private/var`) turns every relative key into an absolute path.
    let rootPrefix = root.resolvingSymlinksInPath().path + "/"
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
      else { continue }
      let resolved = url.resolvingSymlinksInPath().path
      guard resolved.hasPrefix(rootPrefix) else { continue }
      if let data = try? Data(contentsOf: url) {
        files[String(resolved.dropFirst(rootPrefix.count))] = data
      }
    }
    return files
  }

  /// Text files get the old identity swapped for the new; anything that doesn't
  /// decode as UTF-8 passes through untouched rather than being corrupted by a
  /// byte-level splice.
  static func rewriting(_ data: Data, replacing old: String, with new: String) -> Data {
    guard let text = String(data: data, encoding: .utf8) else { return data }
    return Data(text.replacingOccurrences(of: old, with: new).utf8)
  }

  static func write(_ data: Data, to url: URL) -> Bool {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
  }
}
