import Foundation

/// Where `GraphcodeSettings` lives: `~/.graphcode/settings.json`.
///
/// A file rather than `UserDefaults`, because the **daemon** is what builds a session's
/// launch command and it is a different process with a different domain — settings kept in
/// the app's defaults would be invisible to the thing they configure.
///
/// Read fresh on every use rather than cached. A session starts once every few minutes at
/// most, so the read costs nothing measurable, and it means changing a setting in the app
/// applies to the next loop the daemon starts without restarting anything.
public enum GraphcodeSettingsStore {
  public static var url: URL {
    SupportDirectory.url.appendingPathComponent("settings.json")
  }

  /// Never throws and never returns nothing. A missing file is the first launch; a
  /// corrupt one is someone's hand-edit or a half-written save. Both mean "use the
  /// defaults" — refusing to start sessions because a preferences file didn't parse
  /// would be a far worse failure than quietly ignoring it.
  public static func load(from url: URL = GraphcodeSettingsStore.url) -> GraphcodeSettings {
    guard let data = try? Data(contentsOf: url),
      let settings = try? JSONDecoder().decode(GraphcodeSettings.self, from: data)
    else { return GraphcodeSettings() }
    return settings
  }

  @discardableResult
  public static func save(
    _ settings: GraphcodeSettings, to url: URL = GraphcodeSettingsStore.url
  ) -> Bool {
    let encoder = JSONEncoder()
    // Sorted and indented because this file is meant to be readable — and editable — by
    // the person whose machine it is.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(settings) else { return false }
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
