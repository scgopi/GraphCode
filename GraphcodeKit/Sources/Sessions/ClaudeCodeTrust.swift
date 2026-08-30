import Foundation

/// Seeds Claude Code's folder-trust answer so an unattended session is never parked at
/// its first-run "Quick safety check: Is this a project you created or one you trust?"
/// dialog — the Claude Code twin of `CopilotTrust`, for the same reason: a fresh
/// unattended `claude` on a folder it has never seen stops on that dialog as its very
/// first screen, exits with code 1 when nothing answers it, and takes the loop's opening
/// pass with it (issue #215). No launch flag covers it, and the answer lives only as
/// `projects[<path>].hasTrustDialogAccepted = true` in `~/.claude.json`.
///
/// Pre-trusting the one directory the loop was pointed at is the same consent the human
/// gave by creating the loop there. The write is additive and idempotent, and any
/// failure — unparseable JSON, unwritable file — falls back to today's behaviour: the
/// dialog, answerable by opening the loop.
public enum ClaudeCodeTrust {
  public static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
  }

  /// Sets `projects[directory].hasTrustDialogAccepted = true` unless it is already set.
  /// Never throws and never clobbers: a config it cannot parse is left exactly as found,
  /// and so is a config whose `projects` (or the project's own entry) holds something
  /// other than the expected object — replacing it would trade one known value for a guess.
  public static func ensureTrusted(directory: String, configURL: URL = configURL) {
    guard !directory.isEmpty else { return }
    let fileManager = FileManager.default
    let existing = (try? Data(contentsOf: configURL)) ?? Data()
    var config: [String: Any] = [:]
    if !existing.isEmpty {
      guard let parsed = try? JSONSerialization.jsonObject(with: existing),
        let dictionary = parsed as? [String: Any]
      else { return }
      config = dictionary
    }
    if let value = config["projects"], !(value is [String: Any]) { return }
    var projects = config["projects"] as? [String: Any] ?? [:]
    if let value = projects[directory], !(value is [String: Any]) { return }
    var entry = projects[directory] as? [String: Any] ?? [:]
    guard (entry["hasTrustDialogAccepted"] as? Bool) != true else { return }
    entry["hasTrustDialogAccepted"] = true
    projects[directory] = entry
    config["projects"] = projects
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? fileManager.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Claude Code rewrites this file for every session it runs, and it holds the user's
    // prompt history — so a first write lands private (0600) and an existing file keeps
    // whatever permissions it had, rather than `.atomic`'s default 0644 widening it.
    let attributes = try? fileManager.attributesOfItem(atPath: configURL.path)
    let permissions =
      (attributes?[.posixPermissions] as? NSNumber).map { $0.uint16Value } ?? 0o600
    try? data.write(to: configURL, options: .atomic)
    try? fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: configURL.path)
  }
}
