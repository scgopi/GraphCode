import Foundation

public enum ClaudeTrust {
  public static var configURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
  }

  public static func ensureTrusted(directory: String, configURL: URL = configURL) {
    guard !directory.isEmpty else { return }
    var config: [String: Any] = [:]
    if let data = try? Data(contentsOf: configURL), !data.isEmpty {
      guard let parsed = try? JSONSerialization.jsonObject(with: data),
        let dictionary = parsed as? [String: Any]
      else { return }
      config = dictionary
    }
    if let value = config["projects"], !(value is [String: Any]) { return }
    var projects = config["projects"] as? [String: Any] ?? [:]
    if let value = projects[directory], !(value is [String: Any]) { return }
    var project = projects[directory] as? [String: Any] ?? [:]
    guard project["hasTrustDialogAccepted"] as? Bool != true else { return }
    project["hasTrustDialogAccepted"] = true
    projects[directory] = project
    config["projects"] = projects
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return }
    try? FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: configURL, options: .atomic)
  }
}
