import Foundation

/// Seeds Copilot's folder-trust list so an unattended session is never parked at the
/// trust-this-folder dialog — the local twin of the remote ensure's
/// `copilotTrustSeedScript`, which learned this first: `--yolo` does not cover folder
/// trust (measured), and a fresh unattended Copilot boots to an idle screen with its
/// `--interactive` goal queued behind a dialog nobody is present to answer. Anything
/// typed into the session while that dialog is up — a time-based loop's opening pass —
/// is swallowed outright.
///
/// Pre-trusting the one directory the loop was pointed at is the same consent the human
/// gave by creating the loop there. The write is additive and idempotent, and any
/// failure falls back to today's behaviour: the dialog, answerable by opening the loop.
///
/// The file's shape was read off a real "remember this folder" answer, including the
/// detail the remote script missed: Copilot writes `// …` comment lines above the JSON
/// ("This file is managed automatically"), so a plain JSON parse fails on a real file.
/// The header is carried through the rewrite untouched.
public enum CopilotTrust {
  public static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".copilot/config.json")
  }

  /// Adds `directory` to `trustedFolders` unless it is already there. Never throws and
  /// never clobbers: a config it cannot parse is left exactly as found.
  public static func ensureTrusted(directory: String, configURL: URL = configURL) {
    guard !directory.isEmpty else { return }
    let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    let lines = existing.components(separatedBy: "\n")
    let header = lines.prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    let body = lines.dropFirst(header.count).joined(separator: "\n")
    var config: [String: Any] = [:]
    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
        let dictionary = parsed as? [String: Any]
      else { return }
      config = dictionary
    }
    var trusted = config["trustedFolders"] as? [String] ?? []
    guard !trusted.contains(directory) else { return }
    trusted.append(directory)
    config["trustedFolders"] = trusted
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    let text =
      (header.isEmpty ? "" : header.joined(separator: "\n") + "\n")
      + String(decoding: data, as: UTF8.self) + "\n"
    try? FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: configURL, options: .atomic)
  }
}
