import Foundation

/// A loop's memory across passes and relaunches: one append-only log per node, plus a
/// budgeted "wake digest" the next session is pointed at before it starts.
///
/// Without this, every relaunched session opened with the same static prompt as pass
/// one — no idea what was already tried, what the critic rejected, or how the metric
/// has been trending. The design follows OptMem's split: the **log is the truth**
/// (append-only, never edited, unbounded), and anything derived from it — the wake
/// digest here — is a bounded, rebuildable cache. What enters the loop's context is
/// governed by a *reading* budget (`wakeLineBudget`), not by how much has been stored.
///
/// Two writers, one log:
/// - `graphcoded` appends objective episode records (pass started, resolved, metric
///   readings, staged hand-offs) via `GraphStore`'s `onAppendMemory` hook — facts that
///   exist even when a session crashed and can't be trusted to self-report.
/// - The session itself appends learned notes through `graphcode node memo …` — the
///   *why* only the agent knows.
///
/// Files live under the support directory, never inside the user's project: graphcode
/// never writes into an opened folder, and a log in the worktree would be clobbered by
/// the very git operations the loop performs.
///
/// The digest is delivered by *path*, the `SessionBriefing` lesson: a typed launch
/// command tops out under `MAX_CANON`, so the pointer is ~90 bytes and the file is free
/// to be as long as its budget allows.
public enum NodeMemory {
  public static let logFileName = "LOG.txt"
  public static let wakeFileName = "WAKE.md"
  public static let promptFileName = "PROMPT.md"

  /// How many recent log lines a wake digest carries verbatim (~a few KB). Older
  /// entries are elided with a pointer at the full log — available on demand, out of
  /// the default view.
  public static let wakeLineBudget = 40

  /// Notes are capped the way OptMem caps them: forcing salience at write time is what
  /// keeps the log a memory rather than a transcript.
  public static let maxEntryBytes = 512

  /// One directory per (project, node). The project component reuses
  /// `SessionBriefing.slug` so a human browsing `~/.graphcode/memory` can tell which
  /// project a log belongs to.
  public static func directory(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL {
    baseURL
      .appendingPathComponent("memory", isDirectory: true)
      .appendingPathComponent(SessionBriefing.slug(for: projectPath), isDirectory: true)
      .appendingPathComponent(nodeID.uuidString, isDirectory: true)
  }

  public static func logURL(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL {
    directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(logFileName)
  }

  /// Appends one timestamped entry. Newlines are flattened — the log is line-oriented,
  /// and an entry that could smuggle a line break would corrupt every reader. Oversized
  /// entries are truncated, not refused: a partial memory beats a lost one.
  ///
  /// Failures are swallowed for the same reason `SessionBriefing.write`'s are: a loop
  /// with no memory is the pre-memory behaviour, which works, where failing the
  /// operation that tried to record something would trade a note for a loop.
  public static func append(
    _ entry: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    let flattened =
      entry
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !flattened.isEmpty else { return }
    let capped =
      flattened.utf8.count <= maxEntryBytes
      ? flattened
      : String(decoding: Array(flattened.utf8.prefix(maxEntryBytes)), as: UTF8.self)
    let line = "\(Date().ISO8601Format())  \(capped)\n"

    let url = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if !fileManager.fileExists(atPath: url.path) {
        try line.write(to: url, atomically: true, encoding: .utf8)
        return
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
    } catch {
      return
    }
  }

  /// Every entry, oldest first. The full history — `recall`, not `wake`.
  public static func entries(
    forProjectPath projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> [String] {
    let url = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).map(String.init)
  }

  /// Writes the wake digest — the budgeted view a fresh session reads before starting —
  /// and returns its path, or `nil` when the node has no memory yet (a first launch
  /// should not be told to go read an empty file).
  ///
  /// Rewritten on every launch rather than cached, like the briefing: one small write
  /// per session start, and the digest can never go stale against a log that grew
  /// underneath it.
  public static func writeWakeDigest(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL? {
    let all = entries(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
    guard !all.isEmpty else { return nil }

    let recent = all.suffix(wakeLineBudget)
    let elided = all.count - recent.count
    let logPath = logURL(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL).path

    var lines: [String] = [
      "# Loop memory",
      "",
      "What has happened to this loop across its passes, oldest first. Read it before",
      "working: do not re-try what is recorded as a dead end, and continue from where",
      "the last pass left off. Record anything you learn that a future pass must know",
      "with: graphcode node memo <project-path> <your-node-id> <note>",
      "",
    ]
    if elided > 0 {
      lines.append("(\(elided) earlier entries elided — full log: \(logPath))")
      lines.append("")
    }
    lines.append(contentsOf: recent)
    let digest = lines.joined(separator: "\n") + "\n"

    let url = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(wakeFileName)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try digest.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  /// Writes a node's full prompt to its `PROMPT.md` and returns where it landed, or
  /// `nil` when writing failed.
  ///
  /// This is the launch path's last-resort delivery for a prompt too long to type: the
  /// command `zmx` types into a session tops out under `MAX_CANON` (1024 bytes), and a
  /// multi-KB goal overran it — the tty ate the tail mid-word, the shell parked at a
  /// continuation prompt, and the node read `running` while no backend process existed
  /// (issue #57). A file has no length limit, so the goal rides here and the typed line
  /// carries only `promptPointer`.
  ///
  /// It lives beside the wake digest deliberately: same per-node lifecycle (`remove`
  /// cleans both), same remote delivery channel, and the directory is already what a
  /// path-verifying backend gets granted.
  public static func writePrompt(
    _ text: String, projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) -> URL? {
    let url = directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL)
      .appendingPathComponent(promptFileName)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  /// What gets typed in the prompt's place. ASCII only, plain words on both sides of
  /// the path — this string rides the same hostile route as the briefing pointer
  /// (argv, zmx's typed command line, a canonical-mode tty, sometimes ssh), where an
  /// em dash next to the path once ate the file extension (`SessionBriefing.pointer`).
  public static func promptPointer(toPromptAt path: String) -> String {
    "Your complete instructions are in the file at \(path) - read that file first and "
      + "carry out everything it says."
  }

  /// Removes a node's memory directory — called when the node itself is deleted, the
  /// same moment its session is torn down. A log for a loop that no longer exists is
  /// not history, it's litter.
  public static func remove(
    projectPath: String, nodeID: UUID, baseURL: URL = SupportDirectory.url
  ) {
    try? FileManager.default.removeItem(
      at: directory(forProjectPath: projectPath, nodeID: nodeID, baseURL: baseURL))
  }
}
